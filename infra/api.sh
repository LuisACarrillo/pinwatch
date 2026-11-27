#!/usr/bin/env bash
# Publica la API de PinWatch en Lambda, detrás de API Gateway HTTP, dentro de la VPC
# para llegar a la RDS. Suscribe la misma Lambda a pinwatch-events para cerrar el Flujo 2.
#
#   infra/api.sh up       crea o actualiza red, Lambda, API Gateway y la suscripción
#   infra/api.sh status   muestra el estado de cada pieza
#   infra/api.sh down     borra la API, la Lambda, los endpoints y los security groups
#
# Los endpoints de interfaz (Secrets Manager y SNS) cobran unos USD 0.01/h cada uno
# mientras existan, aunque el laboratorio esté apagado. down los borra.
#
# Variables opcionales:
#   API_RUNTIME     runtime de la Lambda (python3.12 por defecto; los wheels son para esa versión)
#   SNS_TOPIC_NAME  tópico al que se suscribe (pinwatch-events por defecto)
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$INFRA_DIR")"
source "$INFRA_DIR/lib.sh"

# Los mensajes de las funciones cuyo stdout se captura van a stderr.
note() { printf '[%s] %s\n' "$(basename "$0" .sh)" "$*" >&2; }

FUNCTION_NAME="pinwatch-api"
API_NAME="pinwatch-api"
API_SG_NAME="pinwatch-api-sg"
VPCE_SG_NAME="pinwatch-vpce-sg"
DB_SG_NAME="pinwatch-db-sg"
RUNTIME="${API_RUNTIME:-python3.12}"
PYTHON_VERSION="${RUNTIME#python}"
ARCHITECTURE="x86_64"
PLATFORM="manylinux2014_x86_64"
DIST_DIR="$REPO_DIR/dist"
ZIP_PATH="$DIST_DIR/api.zip"
LOG_GROUP="/aws/lambda/$FUNCTION_NAME"
LOG_RETENTION_DAYS=7
SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-pinwatch-events}"
APP_SECRET_NAME="${APP_SECRET_NAME:-pinwatch/app}"

set_names() {
  ORIGINALS_BUCKET="${ORIGINALS_BUCKET:-pinwatch-originals-$ACCOUNT_ID}"
  PROCESSED_BUCKET="${PROCESSED_BUCKET:-pinwatch-processed-$ACCOUNT_ID}"
  WEB_BUCKET="${WEB_BUCKET:-pinwatch-web-$ACCOUNT_ID}"
  WEB_ORIGIN="http://${WEB_BUCKET}.s3-website-${AWS_REGION}.amazonaws.com"
}

default_vpc() {
  local vpc
  vpc="$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' --output text)"
  [[ "$vpc" != "None" && -n "$vpc" ]] || die "La cuenta no tiene VPC por defecto."
  printf '%s\n' "$vpc"
}

find_sg() {
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$1" "Name=tag:Project,Values=$PROJECT_TAG" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true
}

find_topic_arn() {
  aws sns list-topics --query "Topics[?ends_with(TopicArn, ':$SNS_TOPIC_NAME')].TopicArn" \
    --output text 2>/dev/null | grep -v '^None$' || true
}

function_exists() { aws lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; }

find_api_id() {
  aws apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId | [0]" \
    --output text 2>/dev/null | grep -v '^None$' || true
}

# Un solo subnet, el de la zona de la RDS si ya existe, para no pagar endpoints en varias zonas.
pick_subnet() {
  local vpc="$1" az subnet
  az="$(aws rds describe-db-instances --db-instance-identifier pinwatch-db \
    --query 'DBInstances[0].AvailabilityZone' --output text 2>/dev/null || true)"
  if [[ -n "$az" && "$az" != "None" ]]; then
    subnet="$(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$vpc" "Name=availability-zone,Values=$az" \
      "Name=default-for-az,Values=true" \
      --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)"
    if [[ -n "$subnet" && "$subnet" != "None" ]]; then
      printf '%s\n' "$subnet"
      return
    fi
  fi
  subnet="$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$vpc" "Name=default-for-az,Values=true" \
    --query 'Subnets[0].SubnetId' --output text)"
  [[ "$subnet" != "None" && -n "$subnet" ]] || die "La VPC $vpc no tiene subnets."
  printf '%s\n' "$subnet"
}

route_table_for() {
  local subnet="$1" vpc="$2" rtb
  rtb="$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$subnet" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true)"
  if [[ -z "$rtb" || "$rtb" == "None" ]]; then
    rtb="$(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=$vpc" "Name=association.main,Values=true" \
      --query 'RouteTables[0].RouteTableId' --output text)"
  fi
  [[ "$rtb" != "None" && -n "$rtb" ]] || die "No hay tabla de ruteo para la subnet $subnet."
  printf '%s\n' "$rtb"
}

find_endpoint() {
  local vpc="$1" service="$2"
  aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$vpc" "Name=service-name,Values=$service" \
    --query 'VpcEndpoints[?State!=`deleted` && State!=`deleting` && State!=`failed`].VpcEndpointId | [0]' \
    --output text 2>/dev/null | grep -v '^None$' || true
}

wait_endpoint() {
  local id="$1" state
  local _
  for _ in $(seq 1 60); do
    state="$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$id" \
      --query 'VpcEndpoints[0].State' --output text 2>/dev/null || true)"
    [[ "$state" == "available" ]] && return 0
    [[ "$state" == "failed" || "$state" == "deleted" || "$state" == "rejected" ]] &&
      die "El endpoint $id quedó en estado $state."
    sleep 5
  done
  die "El endpoint $id no quedó disponible."
}

wait_function() {
  aws lambda wait function-updated-v2 --function-name "$FUNCTION_NAME"
}

ensure_sg() {
  local name="$1" vpc="$2" sg
  sg="$(find_sg "$name")"
  if [[ -z "$sg" ]]; then
    sg="$(aws ec2 create-security-group --group-name "$name" --vpc-id "$vpc" \
      --description "PinWatch $name" \
      --tag-specifications "$(tag_spec security-group "$name")" \
      --query GroupId --output text)"
    note "Security group creado: $name ($sg)"
  else
    note "Security group existente: $name ($sg)"
  fi
  printf '%s\n' "$sg"
}

allow_ingress_from_sg() {
  local sg="$1" port="$2" source="$3" has_rule
  has_rule="$(aws ec2 describe-security-groups --group-ids "$sg" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`$port\` && ToPort==\`$port\` && UserIdGroupPairs[?GroupId=='$source']].FromPort" \
    --output text 2>/dev/null || true)"
  if [[ -z "$has_rule" || "$has_rule" == "None" ]]; then
    aws ec2 authorize-security-group-ingress --group-id "$sg" \
      --protocol tcp --port "$port" --source-group "$source" >/dev/null
    log "Puerto $port abierto en $sg desde $source"
  fi
}

ensure_gateway_endpoint() {
  local vpc="$1" rtb="$2" service id
  service="com.amazonaws.${AWS_REGION}.s3"
  id="$(find_endpoint "$vpc" "$service")"
  if [[ -z "$id" ]]; then
    id="$(aws ec2 create-vpc-endpoint --vpc-id "$vpc" --service-name "$service" \
      --vpc-endpoint-type Gateway --route-table-ids "$rtb" \
      --tag-specifications "$(tag_spec vpc-endpoint pinwatch-s3)" \
      --query 'VpcEndpoint.VpcEndpointId' --output text)"
    log "Endpoint de gateway S3 creado: $id"
  else
    aws ec2 modify-vpc-endpoint --vpc-endpoint-id "$id" --add-route-table-ids "$rtb" >/dev/null 2>&1 || true
    log "Endpoint de gateway S3 existente: $id"
  fi
}

ensure_interface_endpoint() {
  local vpc="$1" subnet="$2" sg="$3" short="$4" service id
  service="com.amazonaws.${AWS_REGION}.${short}"
  id="$(find_endpoint "$vpc" "$service")"
  if [[ -z "$id" ]]; then
    id="$(aws ec2 create-vpc-endpoint --vpc-id "$vpc" --service-name "$service" \
      --vpc-endpoint-type Interface --subnet-ids "$subnet" --security-group-ids "$sg" \
      --private-dns-enabled \
      --tag-specifications "$(tag_spec vpc-endpoint "pinwatch-$short")" \
      --query 'VpcEndpoint.VpcEndpointId' --output text)"
    log "Endpoint de interfaz $short creado: $id (cobra aunque el lab esté apagado)"
  else
    log "Endpoint de interfaz $short existente: $id"
  fi
  wait_endpoint "$id"
}

build_zip() {
  require_cmd python3
  python3 -m pip --version >/dev/null 2>&1 || die "Falta pip. En Ubuntu: sudo apt-get install -y python3-pip"
  local build req
  build="$(mktemp -d)"
  req="$(mktemp)"
  mkdir -p "$DIST_DIR"

  python3 - "$REPO_DIR/backend/requirements.txt" "$req" <<'PY'
import sys
skip = ("boto3==", "uvicorn==")
with open(sys.argv[1], encoding="utf-8") as source, open(sys.argv[2], "w", encoding="utf-8") as target:
    for line in source:
        if line.startswith(skip):
            continue
        target.write(line)
PY
  log "Instalando dependencias de la API para $PLATFORM / Python $PYTHON_VERSION"
  python3 -m pip install --quiet --disable-pip-version-check --target "$build" \
    --platform "$PLATFORM" --implementation cp --python-version "$PYTHON_VERSION" \
    --only-binary=:all: -r "$req"
  rm -f "$req"

  cp "$REPO_DIR/backend/main.py" "$REPO_DIR/backend/auth.py" \
    "$REPO_DIR/backend/app_secrets.py" "$REPO_DIR/backend/database.py" \
    "$REPO_DIR/backend/sns.py" "$REPO_DIR/backend/image_events.py" "$build/"
  mkdir -p "$build/image_processor"
  cp "$REPO_DIR/backend/image_processor/__init__.py" \
    "$REPO_DIR/backend/image_processor/keys.py" "$build/image_processor/"

  if [[ "$(uname -s)" == "Linux" ]] &&
    [[ "$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')" == "$PYTHON_VERSION" ]]; then
    (cd "$build" && python3 -c 'import sys; sys.path.insert(0, "."); import fastapi, mangum, psycopg2, jwt, argon2; from image_processor.keys import output_keys') ||
      die "El paquete de la API no importa en Linux con Python $PYTHON_VERSION."
    log "Paquete probado en local: importan FastAPI, psycopg2 y las llaves de imagen."
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

lambda_environment() {
  local topic="$1"
  ORIGINALS_BUCKET="$ORIGINALS_BUCKET" PROCESSED_BUCKET="$PROCESSED_BUCKET" \
    SNS_TOPIC_ARN="$topic" APP_SECRET_NAME="$APP_SECRET_NAME" CORS_ORIGINS="$WEB_ORIGIN" \
    python3 -c 'import json, os; print(json.dumps({"Variables": {key: os.environ[key] for key in ("ORIGINALS_BUCKET", "PROCESSED_BUCKET", "SNS_TOPIC_ARN", "APP_SECRET_NAME", "CORS_ORIGINS")}}))'
}

deploy_function() {
  local topic="$1" subnet="$2" sg="$3" role environment
  role="$(lab_role_arn)"
  environment="$(lambda_environment "$topic")"

  if ! function_exists; then
    log "Creando la Lambda $FUNCTION_NAME ($RUNTIME) dentro de la VPC"
    aws lambda create-function \
      --function-name "$FUNCTION_NAME" \
      --runtime "$RUNTIME" \
      --architectures "$ARCHITECTURE" \
      --role "$role" \
      --handler main.handler \
      --zip-file "fileb://$ZIP_PATH" \
      --timeout 30 \
      --memory-size 512 \
      --environment "$environment" \
      --vpc-config "SubnetIds=$subnet,SecurityGroupIds=$sg" \
      --description "PinWatch API: FastAPI en Lambda, suscrita a pinwatch-events" \
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
    --handler main.handler \
    --timeout 30 \
    --memory-size 512 \
    --environment "$environment" \
    --vpc-config "SubnetIds=$subnet,SecurityGroupIds=$sg" >/dev/null
  wait_function

  local local_hash remote_hash
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
  aws lambda put-function-event-invoke-config --function-name "$FUNCTION_NAME" \
    --maximum-retry-attempts 2 --maximum-event-age-in-seconds 3600 >/dev/null
  aws logs create-log-group --log-group-name "$LOG_GROUP" \
    --tags "Project=$PROJECT_TAG,Owner=$OWNER_TAG" 2>/dev/null || true
  aws logs put-retention-policy --log-group-name "$LOG_GROUP" \
    --retention-in-days "$LOG_RETENTION_DAYS"
  log "Logs en $LOG_GROUP con retención de $LOG_RETENTION_DAYS días. Reintentos asíncronos: 2."
}

allow_apigateway() {
  local api_id="$1"
  if aws lambda get-policy --function-name "$FUNCTION_NAME" --query Policy --output text 2>/dev/null |
    grep -q 'apigateway-invoke'; then
    return 0
  fi
  aws lambda add-permission --function-name "$FUNCTION_NAME" \
    --statement-id apigateway-invoke \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${api_id}/*/*" >/dev/null
  note "Permiso para que API Gateway invoque la Lambda."
}

ensure_http_api() {
  local api_id endpoint
  api_id="$(find_api_id)"
  if [[ -z "$api_id" ]]; then
    local function_arn
    function_arn="$(aws lambda get-function --function-name "$FUNCTION_NAME" \
      --query Configuration.FunctionArn --output text)"
    api_id="$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP \
      --target "$function_arn" \
      --tags "Project=$PROJECT_TAG,Owner=$OWNER_TAG" \
      --query ApiId --output text)"
    note "API Gateway HTTP creada: $api_id"
  else
    note "API Gateway HTTP existente: $api_id"
  fi
  # --target a veces no deja el permiso. Sin él, API Gateway responde 500 y la Lambda no corre.
  allow_apigateway "$api_id"
  endpoint="$(aws apigatewayv2 get-api --api-id "$api_id" --query ApiEndpoint --output text)"
  printf '%s\n' "$endpoint"
}

ensure_sns_subscription() {
  local topic="$1" function_arn existing
  function_arn="$(aws lambda get-function --function-name "$FUNCTION_NAME" \
    --query Configuration.FunctionArn --output text)"
  if ! aws lambda get-policy --function-name "$FUNCTION_NAME" --query Policy --output text 2>/dev/null |
    grep -q 'sns-pinwatch-events'; then
    aws lambda add-permission --function-name "$FUNCTION_NAME" \
      --statement-id sns-pinwatch-events \
      --action lambda:InvokeFunction \
      --principal sns.amazonaws.com \
      --source-arn "$topic" >/dev/null
    log "Permiso para que SNS invoque la Lambda."
  fi

  existing="$(aws sns list-subscriptions-by-topic --topic-arn "$topic" \
    --query "Subscriptions[?Endpoint=='$function_arn'].SubscriptionArn | [0]" --output text 2>/dev/null || true)"
  if [[ -z "$existing" || "$existing" == "None" || "$existing" == "PendingConfirmation" ]]; then
    existing="$(aws sns subscribe --topic-arn "$topic" --protocol lambda \
      --notification-endpoint "$function_arn" \
      --return-subscription-arn \
      --attributes '{"FilterPolicy":"{\"event_type\":[\"imagen_procesada\",\"imagen_rechazada\"]}","FilterPolicyScope":"MessageAttributes"}' \
      --query SubscriptionArn --output text)"
    log "Suscripción creada: $existing"
  else
    aws sns set-subscription-attributes --subscription-arn "$existing" \
      --attribute-name FilterPolicy \
      --attribute-value '{"event_type":["imagen_procesada","imagen_rechazada"]}' >/dev/null
    aws sns set-subscription-attributes --subscription-arn "$existing" \
      --attribute-name FilterPolicyScope --attribute-value MessageAttributes >/dev/null
    log "Suscripción existente, filtro actualizado: $existing"
  fi
}

probe_feed() {
  local endpoint="$1" attempt body code
  require_cmd curl
  for attempt in 1 2 3; do
    body="$(mktemp)"
    code="$(curl -sS --max-time 40 -o "$body" -w '%{http_code}' "$endpoint/feed" || true)"
    if [[ "$code" == "200" ]]; then
      log "GET /feed respondió 200. La Lambda llega a la RDS."
      rm -f "$body"
      return 0
    fi
    warn "Intento $attempt de GET /feed: HTTP ${code:-sin respuesta} $(head -c 300 "$body" 2>/dev/null || true)"
    rm -f "$body"
    sleep 8
  done
  die "La API no respondió 200 en /feed. Revisa $LOG_GROUP."
}

api_up() {
  require_cmd python3
  require_cmd openssl
  set_names
  local topic vpc subnet rtb api_sg vpce_sg db_sg endpoint
  topic="$(find_topic_arn)"
  [[ -n "$topic" ]] || die "No existe el tópico $SNS_TOPIC_NAME. Corre antes: bash infra/sns.sh up"
  vpc="$(default_vpc)"
  subnet="$(pick_subnet "$vpc")"
  rtb="$(route_table_for "$subnet" "$vpc")"
  log "VPC $vpc, subnet $subnet, tabla $rtb"

  api_sg="$(ensure_sg "$API_SG_NAME" "$vpc")"
  vpce_sg="$(ensure_sg "$VPCE_SG_NAME" "$vpc")"
  allow_ingress_from_sg "$vpce_sg" 443 "$api_sg"
  db_sg="$(find_sg "$DB_SG_NAME")"
  [[ -n "$db_sg" ]] || die "No existe $DB_SG_NAME. Corre antes: bash infra/rds.sh up"
  allow_ingress_from_sg "$db_sg" 5432 "$api_sg"

  ensure_gateway_endpoint "$vpc" "$rtb"
  ensure_interface_endpoint "$vpc" "$subnet" "$vpce_sg" secretsmanager
  ensure_interface_endpoint "$vpc" "$subnet" "$vpce_sg" sns
  log "Aviso de costo: Secrets Manager y SNS por endpoint de interfaz, unos USD 0.01/h cada uno, hasta bash infra/api.sh down."

  build_zip
  deploy_function "$topic" "$subnet" "$api_sg"
  configure_function
  endpoint="$(ensure_http_api)"
  ensure_sns_subscription "$topic"
  probe_feed "$endpoint"

  log "API lista: $endpoint"
  log "El frontend publicado puede llamar desde $WEB_ORIGIN"
}

api_status() {
  set_names
  if function_exists; then
    log "$FUNCTION_NAME: $(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" \
      --query '[State, Runtime, VpcConfig.VpcId]' --output text)"
  else
    log "$FUNCTION_NAME: no existe"
  fi
  local api_id
  api_id="$(find_api_id)"
  if [[ -n "$api_id" ]]; then
    log "API Gateway $API_NAME: $(aws apigatewayv2 get-api --api-id "$api_id" --query ApiEndpoint --output text)"
  else
    log "API Gateway $API_NAME: no existe"
  fi
  local topic
  topic="$(find_topic_arn)"
  if [[ -n "$topic" ]] && function_exists; then
    local function_arn sub
    function_arn="$(aws lambda get-function --function-name "$FUNCTION_NAME" \
      --query Configuration.FunctionArn --output text)"
    sub="$(aws sns list-subscriptions-by-topic --topic-arn "$topic" \
      --query "Subscriptions[?Endpoint=='$function_arn'].SubscriptionArn | [0]" --output text 2>/dev/null || true)"
    if [[ -n "$sub" && "$sub" != "None" ]]; then
      log "Suscripción SNS: $sub"
    else
      log "Suscripción SNS: no configurada"
    fi
  fi
}

delete_our_endpoints() {
  local ids
  ids="$(aws ec2 describe-vpc-endpoints \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=tag:Name,Values=pinwatch-s3,pinwatch-secretsmanager,pinwatch-sns" \
    --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' --output text 2>/dev/null || true)"
  [[ -n "$ids" && "$ids" != "None" ]] || return 0
  # shellcheck disable=SC2086
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $ids >/dev/null
  log "Endpoints en borrado: $ids"
  local _
  for _ in $(seq 1 30); do
    ids="$(aws ec2 describe-vpc-endpoints \
      --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=tag:Name,Values=pinwatch-s3,pinwatch-secretsmanager,pinwatch-sns" \
      --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' --output text 2>/dev/null || true)"
    [[ -z "$ids" || "$ids" == "None" ]] && return 0
    sleep 5
  done
  warn "Los endpoints siguen borrándose. Si el security group no sale, repite el down en un minuto."
}

delete_sg_when_free() {
  local sg="$1" name="$2"
  local _
  [[ -n "$sg" ]] || return 0
  for _ in $(seq 1 18); do
    if aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1; then
      log "Security group $name eliminado."
      return 0
    fi
    sleep 10
  done
  warn "No se pudo borrar $name ($sg): su interfaz de red sigue en uso. Repite bash infra/api.sh down --yes en un minuto."
}

api_down() {
  set_names
  local api_id topic function_arn
  api_id="$(find_api_id)"
  topic="$(find_topic_arn)"
  if [[ -z "$api_id" ]] && ! function_exists && [[ -z "$(find_sg "$API_SG_NAME")" ]]; then
    log "No hay API publicada; nada que borrar."
    return
  fi
  confirm "¿Borrar la API $API_NAME, la Lambda $FUNCTION_NAME y los endpoints de VPC? (la RDS y los buckets de imágenes se quedan)" ||
    die "Cancelado."

  if [[ -n "$api_id" ]]; then
    aws apigatewayv2 delete-api --api-id "$api_id"
    log "API Gateway $api_id borrada."
  fi
  if [[ -n "$topic" ]] && function_exists; then
    function_arn="$(aws lambda get-function --function-name "$FUNCTION_NAME" \
      --query Configuration.FunctionArn --output text)"
    local sub
    sub="$(aws sns list-subscriptions-by-topic --topic-arn "$topic" \
      --query "Subscriptions[?Endpoint=='$function_arn'].SubscriptionArn | [0]" --output text 2>/dev/null || true)"
    if [[ -n "$sub" && "$sub" != "None" && "$sub" != "PendingConfirmation" ]]; then
      aws sns unsubscribe --subscription-arn "$sub"
      log "Suscripción SNS borrada."
    fi
  fi
  if function_exists; then
    aws lambda delete-function --function-name "$FUNCTION_NAME"
    log "Lambda $FUNCTION_NAME borrada."
  fi
  aws logs delete-log-group --log-group-name "$LOG_GROUP" 2>/dev/null &&
    log "Log group $LOG_GROUP borrado." || true

  delete_our_endpoints

  local api_sg db_sg
  api_sg="$(find_sg "$API_SG_NAME")"
  db_sg="$(find_sg "$DB_SG_NAME")"
  if [[ -n "$api_sg" && -n "$db_sg" ]]; then
    aws ec2 revoke-security-group-ingress --group-id "$db_sg" \
      --protocol tcp --port 5432 --source-group "$api_sg" >/dev/null 2>&1 || true
    log "Regla 5432 de la RDS hacia la API retirada."
  fi
  delete_sg_when_free "$(find_sg "$VPCE_SG_NAME")" "$VPCE_SG_NAME"
  delete_sg_when_free "$api_sg" "$API_SG_NAME"
}

parse_args "$@"
aws_session
"api_$ACTION"
