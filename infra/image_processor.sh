#!/usr/bin/env bash
# Flujo 2: Lambda que procesa las imágenes que llegan a s3://pinwatch-originals-<cuenta>/originals/.
#   infra/image_processor.sh up       crea o actualiza bucket processed, Lambda, permiso y notificación
#   infra/image_processor.sh status   muestra el estado de cada pieza
#   infra/image_processor.sh down     quita la notificación, la Lambda, sus logs y el bucket processed
#
# El bucket de originales es de Luis Alberto (infra/setup_originals_bucket.py): up lo crea si
# falta, pero down nunca lo borra. De su notificación solo se toca la entrada de esta Lambda.
# La Lambda queda fuera de la VPC y no toca la RDS: publica el resultado en el tópico SNS de
# Dario (pinwatch-events) y down no lo borra.
#
# Variables opcionales:
#   LAMBDA_RUNTIME  runtime de Python de la Lambda (python3.14 por defecto)
#   SNS_TOPIC_NAME  tópico donde se publican los resultados (pinwatch-events por defecto)
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$INFRA_DIR")"
source "$INFRA_DIR/lib.sh"

FUNCTION_NAME="pinwatch-image-processor"
NOTIFICATION_ID="pinwatch-image-processor"
PERMISSION_SID="s3-originals-invoke"
RUNTIME="${LAMBDA_RUNTIME:-python3.14}"
PYTHON_VERSION="${RUNTIME#python}"
ARCHITECTURE="x86_64"
PLATFORM="manylinux2014_x86_64"
SOURCE_DIR="$REPO_DIR/backend/image_processor"
DIST_DIR="$REPO_DIR/dist"
ZIP_PATH="$DIST_DIR/image_processor.zip"
LOG_GROUP="/aws/lambda/$FUNCTION_NAME"
LOG_RETENTION_DAYS=7
SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-pinwatch-events}"

set_names() {
  ORIGINALS_BUCKET="${ORIGINALS_BUCKET:-pinwatch-originals-$ACCOUNT_ID}"
  PROCESSED_BUCKET="${PROCESSED_BUCKET:-pinwatch-processed-$ACCOUNT_ID}"
}

# El tópico es de Dario (infra/sns.sh); up.sh lo crea antes que el Flujo 2.
find_topic_arn() {
  aws sns list-topics --query "Topics[?ends_with(TopicArn, ':$SNS_TOPIC_NAME')].TopicArn" \
    --output text 2>/dev/null | grep -v '^None$' || true
}

bucket_exists() { aws s3api head-bucket --bucket "$1" >/dev/null 2>&1; }
function_exists() { aws lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; }

ensure_originals_bucket() {
  if bucket_exists "$ORIGINALS_BUCKET"; then
    log "Bucket de originales existente: $ORIGINALS_BUCKET"
  else
    log "No existe $ORIGINALS_BUCKET; se crea con el script de Luis Alberto"
    python3 "$INFRA_DIR/setup_originals_bucket.py"
  fi
}

ensure_processed_bucket() {
  if bucket_exists "$PROCESSED_BUCKET"; then
    log "Bucket processed existente: $PROCESSED_BUCKET"
  else
    aws s3api create-bucket --bucket "$PROCESSED_BUCKET" >/dev/null
    log "Bucket processed creado: $PROCESSED_BUCKET"
  fi
  # Privado: el feed leerá las miniaturas con URLs prefirmadas.
  aws s3api put-public-access-block --bucket "$PROCESSED_BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  aws s3api put-bucket-ownership-controls --bucket "$PROCESSED_BUCKET" \
    --ownership-controls "Rules=[{ObjectOwnership=BucketOwnerEnforced}]"
  aws s3api put-bucket-encryption --bucket "$PROCESSED_BUCKET" \
    --server-side-encryption-configuration \
    "Rules=[{ApplyServerSideEncryptionByDefault={SSEAlgorithm=AES256}}]"
  aws s3api put-bucket-tagging --bucket "$PROCESSED_BUCKET" \
    --tagging "TagSet=[{Key=Project,Value=$PROJECT_TAG},{Key=Owner,Value=$OWNER_TAG}]"
}

# Arma el zip para Linux aunque se corra en WSL: Pillow se instala desde wheels manylinux.
# El zip es determinista (orden y fechas fijas) para que el mismo código dé el mismo hash.
build_zip() {
  require_cmd python3
  local build venv
  build="$(mktemp -d)"
  venv="$DIST_DIR/.build-venv"
  mkdir -p "$DIST_DIR"
  [[ -x "$venv/bin/pip" ]] || python3 -m venv "$venv"

  log "Instalando dependencias para $PLATFORM / Python $PYTHON_VERSION"
  "$venv/bin/pip" install --quiet --disable-pip-version-check --target "$build" \
    --platform "$PLATFORM" --implementation cp --python-version "$PYTHON_VERSION" \
    --only-binary=:all: -r "$SOURCE_DIR/requirements.txt"
  mkdir -p "$build/image_processor"
  cp "$SOURCE_DIR"/*.py "$build/image_processor/"

  # Si esto es Linux y la versión local coincide con el runtime, se prueba el paquete antes de
  # subirlo. En macOS no: el zip trae el Pillow de Linux y no se puede importar ahí.
  if [[ "$(uname -s)" != "Linux" ]]; then
    log "Prueba local del zip omitida: el Pillow del paquete es para Linux y esto es $(uname -s)"
  elif [[ "$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')" == "$PYTHON_VERSION" ]]; then
    # boto3 no viaja en el zip (lo trae el runtime), así que se prueba processing, no handler.
    (cd "$build" && python3 -I -c '
import sys; sys.path.insert(0, ".")
from io import BytesIO
from PIL import Image
from image_processor.processing import process
buffer = BytesIO()
Image.new("RGB", (2000, 1000), "teal").save(buffer, "JPEG")
result = process(buffer.getvalue())
assert (result.thumbnail.width, result.thumbnail.height) == (400, 200)
') || die "El paquete armado no funciona en Linux con Python $PYTHON_VERSION."
    log "Paquete probado en local: el Pillow del zip convierte una imagen a WebP"
  fi

  python3 - "$build" "$ZIP_PATH" <<'EOF'
import os, sys, zipfile
root, target = sys.argv[1], sys.argv[2]
paths = []
for folder, dirs, files in os.walk(root):
    dirs[:] = sorted(d for d in dirs if d != "__pycache__")
    paths += [os.path.join(folder, name) for name in files if not name.endswith(".pyc")]
with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(paths):
        info = zipfile.ZipInfo(os.path.relpath(path, root).replace(os.sep, "/"), (1980, 1, 1, 0, 0, 0))
        info.external_attr = (0o755 if os.access(path, os.X_OK) else 0o644) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(path, "rb") as source:
            archive.writestr(info, source.read())
EOF
  rm -rf "$build"
  log "Zip listo: ${ZIP_PATH#"$REPO_DIR"/} ($(du -h "$ZIP_PATH" | cut -f1))"
}

wait_function() {
  aws lambda wait function-updated-v2 --function-name "$FUNCTION_NAME"
}

deploy_function() {
  local role environment local_hash remote_hash
  role="$(lab_role_arn)"
  environment="$(python3 -c 'import json, sys; print(json.dumps({"Variables": {"PROCESSED_BUCKET": sys.argv[1], "SNS_TOPIC_ARN": sys.argv[2]}}))' \
    "$PROCESSED_BUCKET" "$SNS_TOPIC_ARN")"

  if ! function_exists; then
    log "Creando la Lambda $FUNCTION_NAME ($RUNTIME, $ARCHITECTURE) con LabRole"
    aws lambda create-function \
      --function-name "$FUNCTION_NAME" \
      --runtime "$RUNTIME" \
      --architectures "$ARCHITECTURE" \
      --role "$role" \
      --handler image_processor.handler.handler \
      --zip-file "fileb://$ZIP_PATH" \
      --timeout 60 \
      --memory-size 1024 \
      --environment "$environment" \
      --description "PinWatch Flujo 2: comprime originales y genera miniaturas" \
      --tags "Project=$PROJECT_TAG,Owner=$OWNER_TAG" >/dev/null
    aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME"
    log "Lambda creada."
    return
  fi

  log "Lambda existente: actualizando configuración"
  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --runtime "$RUNTIME" \
    --role "$role" \
    --handler image_processor.handler.handler \
    --timeout 60 \
    --memory-size 1024 \
    --environment "$environment" >/dev/null
  wait_function

  local_hash="$(openssl dgst -sha256 -binary "$ZIP_PATH" | base64)"
  remote_hash="$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" \
    --query CodeSha256 --output text)"
  if [[ "$local_hash" == "$remote_hash" ]]; then
    log "El código no cambió; no se vuelve a subir."
  else
    aws lambda update-function-code --function-name "$FUNCTION_NAME" \
      --zip-file "fileb://$ZIP_PATH" >/dev/null
    wait_function
    log "Código actualizado."
  fi
}

configure_function() {
  # Eventos asíncronos de S3: un reintento como máximo y nada más viejo que una hora.
  aws lambda put-function-event-invoke-config --function-name "$FUNCTION_NAME" \
    --maximum-retry-attempts 1 --maximum-event-age-in-seconds 3600 >/dev/null
  log "Reintentos: máximo 1; eventos de más de 1 h se descartan."

  aws logs create-log-group --log-group-name "$LOG_GROUP" \
    --tags "Project=$PROJECT_TAG,Owner=$OWNER_TAG" 2>/dev/null || true
  aws logs put-retention-policy --log-group-name "$LOG_GROUP" \
    --retention-in-days "$LOG_RETENTION_DAYS"
  log "Logs en $LOG_GROUP con retención de $LOG_RETENTION_DAYS días."

  # Solo S3, desde el bucket de originales de esta cuenta, puede invocar la función.
  aws lambda remove-permission --function-name "$FUNCTION_NAME" \
    --statement-id "$PERMISSION_SID" >/dev/null 2>&1 || true
  aws lambda add-permission --function-name "$FUNCTION_NAME" \
    --statement-id "$PERMISSION_SID" \
    --action lambda:InvokeFunction \
    --principal s3.amazonaws.com \
    --source-arn "arn:aws:s3:::$ORIGINALS_BUCKET" \
    --source-account "$ACCOUNT_ID" >/dev/null
  log "Permiso para que S3 ($ORIGINALS_BUCKET) invoque la Lambda."
}

# put-bucket-notification-configuration reemplaza toda la configuración: se lee la actual,
# se quita solo la entrada con nuestro Id y, en modo add, se agrega de nuevo.
# Uso: update_notification add|remove
update_notification() {
  local mode="$1" current desired function_arn=""
  current="$(mktemp)"
  desired="$(mktemp)"
  aws s3api get-bucket-notification-configuration --bucket "$ORIGINALS_BUCKET" --output json >"$current"
  if [[ "$mode" == "add" ]]; then
    function_arn="$(aws lambda get-function --function-name "$FUNCTION_NAME" \
      --query Configuration.FunctionArn --output text)"
  fi

  # Imprime cuántas notificaciones de otros (SNS, SQS, otras Lambdas) se conservan.
  local others
  others="$(python3 - "$current" "$desired" "$mode" "$NOTIFICATION_ID" "$function_arn" <<'EOF'
import json, sys
current_path, desired_path, mode, entry_id, function_arn = sys.argv[1:6]
text = open(current_path).read().strip()
config = json.loads(text) if text else {}
config.pop("ResponseMetadata", None)
entries = [e for e in config.get("LambdaFunctionConfigurations", []) if e.get("Id") != entry_id]
if mode == "add":
    entries.append({
        "Id": entry_id,
        "LambdaFunctionArn": function_arn,
        "Events": ["s3:ObjectCreated:*"],
        "Filter": {"Key": {"FilterRules": [{"Name": "prefix", "Value": "originals/"}]}},
    })
if entries:
    config["LambdaFunctionConfigurations"] = entries
else:
    config.pop("LambdaFunctionConfigurations", None)
json.dump(config, open(desired_path, "w"))
print(sum(len(v) for v in config.values() if isinstance(v, list)) - (mode == "add"))
EOF
)"

  local output
  if ! output="$(aws s3api put-bucket-notification-configuration --bucket "$ORIGINALS_BUCKET" \
    --notification-configuration "file://$desired" 2>&1)"; then
    rm -f "$current" "$desired"
    [[ "$output" == *"overlapping"* ]] &&
      die "Otra notificación del bucket ya escucha originals/ con los mismos eventos. Hay que coordinarlo con su dueño: $output"
    die "$output"
  fi
  rm -f "$current" "$desired"
  if [[ "$mode" == "add" ]]; then
    log "Notificación $NOTIFICATION_ID: ObjectCreated en originals/ -> $FUNCTION_NAME ($others notificación(es) ajena(s) conservada(s))"
  else
    log "Notificación $NOTIFICATION_ID retirada ($others notificación(es) ajena(s) conservada(s))"
  fi
}

image_processor_up() {
  require_cmd openssl
  set_names
  ensure_originals_bucket
  ensure_processed_bucket
  SNS_TOPIC_ARN="$(find_topic_arn)"
  if [[ -n "$SNS_TOPIC_ARN" ]]; then
    log "Los resultados se publican en $SNS_TOPIC_ARN"
  else
    warn "No existe el tópico $SNS_TOPIC_NAME: los resultados solo quedarán en el log. Créalo con: bash infra/sns.sh up"
  fi
  build_zip
  deploy_function
  configure_function
  update_notification add
  log "Listo: lo que llegue a s3://$ORIGINALS_BUCKET/originals/ se procesa en s3://$PROCESSED_BUCKET/"
}

image_processor_status() {
  set_names
  if function_exists; then
    log "$FUNCTION_NAME: $(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" \
      --query '[State, Runtime, Architectures[0], LastModified]' --output text)"
    local topic
    topic="$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" \
      --query 'Environment.Variables.SNS_TOPIC_ARN' --output text)"
    [[ -n "$topic" && "$topic" != "None" ]] && log "Publica resultados en: $topic" ||
      log "Publica resultados en: (sin tópico; solo log)"
  else
    log "$FUNCTION_NAME: no existe"
  fi
  if bucket_exists "$ORIGINALS_BUCKET"; then
    local ids
    ids="$(aws s3api get-bucket-notification-configuration --bucket "$ORIGINALS_BUCKET" \
      --query 'LambdaFunctionConfigurations[].Id' --output text 2>/dev/null || true)"
    if grep -qw "$NOTIFICATION_ID" <<<"$ids"; then
      log "Notificación en $ORIGINALS_BUCKET: activa"
    else
      log "Notificación en $ORIGINALS_BUCKET: no configurada"
    fi
  else
    log "$ORIGINALS_BUCKET: no existe"
  fi
  if bucket_exists "$PROCESSED_BUCKET"; then
    log "$PROCESSED_BUCKET: $(aws s3 ls "s3://$PROCESSED_BUCKET" --recursive | wc -l | tr -d ' ') objeto(s)"
  else
    log "$PROCESSED_BUCKET: no existe"
  fi
}

image_processor_down() {
  set_names
  local has_notification=0 has_function=0 has_bucket=0
  if bucket_exists "$ORIGINALS_BUCKET" && aws s3api get-bucket-notification-configuration \
    --bucket "$ORIGINALS_BUCKET" --query 'LambdaFunctionConfigurations[].Id' --output text 2>/dev/null |
    grep -qw "$NOTIFICATION_ID"; then
    has_notification=1
  fi
  function_exists && has_function=1
  bucket_exists "$PROCESSED_BUCKET" && has_bucket=1
  if ((has_notification + has_function + has_bucket == 0)); then
    log "No hay nada del Flujo 2; nada que borrar."
    return
  fi
  confirm "¿Quitar la notificación, borrar $FUNCTION_NAME y vaciar y borrar $PROCESSED_BUCKET? (los originales se quedan)" ||
    die "Cancelado."

  # Orden: primero la notificación, para que S3 deje de invocar una función que va a desaparecer.
  ((has_notification)) && update_notification remove
  if ((has_function)); then
    aws lambda delete-function --function-name "$FUNCTION_NAME"
    log "Lambda $FUNCTION_NAME borrada (con su permiso)."
  fi
  aws logs delete-log-group --log-group-name "$LOG_GROUP" 2>/dev/null &&
    log "Log group $LOG_GROUP borrado." || true
  if ((has_bucket)); then
    aws s3 rm "s3://$PROCESSED_BUCKET" --recursive --only-show-errors
    aws s3api delete-bucket --bucket "$PROCESSED_BUCKET"
    log "Bucket $PROCESSED_BUCKET vaciado y borrado."
  fi
}

parse_args "$@"
aws_session
"image_processor_$ACTION"
