#!/usr/bin/env bash
# Comprueba que lo que levanta up.sh funciona de punta a punta. No crea ni borra nada.
#   bash infra/verify.sh
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INFRA_DIR/lib.sh"

APP_SECRET_NAME="${APP_SECRET_NAME:-pinwatch/app}"
FAILURES=0
pass() { log "OK     $*"; }
fail() {
  log "FALLA  $*"
  FAILURES=$((FAILURES + 1))
}

aws_session

# 1. Secreto legible y con llave JWT, sin imprimir valores.
keys="$(aws secretsmanager get-secret-value --secret-id "$APP_SECRET_NAME" \
  --query SecretString --output text 2>/dev/null |
  python3 -c 'import json, sys; s = json.load(sys.stdin); print(len(s.get("jwt_signing_key", "")), ",".join(sorted(s)))' \
    2>/dev/null || true)"
if [[ "$keys" =~ ^([0-9]+)\ (.*)$ ]] && ((BASH_REMATCH[1] >= 64)); then
  pass "Secreto $APP_SECRET_NAME legible; llaves: ${BASH_REMATCH[2]}"
else
  fail "Secreto $APP_SECRET_NAME no se pudo leer o no trae jwt_signing_key"
fi

# 2. Bastión en running y registrado en Session Manager.
id="$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=pinwatch-bastion" "Name=tag:Project,Values=$PROJECT_TAG" \
  "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
if [[ "$id" == "None" ]]; then
  fail "El bastión no está en running"
else
  pass "Bastión en running: $id"
  ping="$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
  [[ "$ping" == "Online" ]] && pass "Registrado en Session Manager" || fail "Session Manager: ${ping:-sin registro}"

  # 3. start-session de verdad: corre psql --version dentro del bastión.
  if command -v session-manager-plugin >/dev/null 2>&1; then
    out="$(ssm_run "$id" "psql --version")"
    version="$(grep -o 'psql (PostgreSQL) [0-9.]*' <<<"$out" || true)"
    [[ -n "$version" ]] && pass "start-session funciona; en el bastión: $version" ||
      fail "start-session no devolvió psql --version -> $(grep . <<<"$out" | tail -n 1)"
  else
    fail "Falta session-manager-plugin en esta máquina"
  fi

  # 4. Sin puertos abiertos en el security group.
  open="$(aws ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text |
    xargs -I{} aws ec2 describe-security-groups --group-ids {} \
      --query 'length(SecurityGroups[0].IpPermissions)' --output text)"
  [[ "$open" == 0 ]] && pass "Security group sin reglas de entrada" ||
    log "AVISO  El security group tiene $open regla(s) de entrada (¿EC2_ACCESS=ssh?)"
fi

# 5. Base de datos RDS PostgreSQL disponible y conectada en Secrets Manager
rds_status="$(aws rds describe-db-instances --db-instance-identifier "pinwatch-db" \
  --query 'DBInstances[0].[DBInstanceStatus, Endpoint.Address]' --output text 2>/dev/null || true)"
if [[ -n "$rds_status" ]]; then
  read -r rds_st rds_ep <<<"$rds_status"
  if [[ "$rds_st" == "available" ]]; then
    pass "RDS pinwatch-db en available: $rds_ep"
  else
    fail "RDS pinwatch-db en estado '$rds_st' (no available)"
  fi
else
  log "AVISO  RDS pinwatch-db no encontrada (ejecuta 'bash infra/rds.sh up' para levantarla)"
fi

# 6. Tópico Amazon SNS existente
sns_arn="$(aws sns list-topics \
  --query "Topics[?ends_with(TopicArn, ':pinwatch-events')].TopicArn" \
  --output text 2>/dev/null | grep -v '^None$' || true)"
if [[ -n "$sns_arn" ]]; then
  pass "Tópico Amazon SNS pinwatch-events existe: $sns_arn"
else
  log "AVISO  Tópico SNS pinwatch-events no encontrado (ejecuta 'bash infra/sns.sh up' para crearlo)"
fi

# 7. Flujo 2 de punta a punta: una imagen válida y un texto disfrazado de .jpg en originals/.
ORIGINALS_BUCKET="${ORIGINALS_BUCKET:-pinwatch-originals-$ACCOUNT_ID}"
PROCESSED_BUCKET="${PROCESSED_BUCKET:-pinwatch-processed-$ACCOUNT_ID}"
LOG_GROUP="/aws/lambda/pinwatch-image-processor"
STAMP="verify-$(date +%s)"
WORK="$(mktemp -d)"
VALID_KEY="originals/$STAMP/prueba.png"
FAKE_KEY="originals/$STAMP/falsa.jpg"

cleanup_flow2() {
  local key
  for key in "$VALID_KEY" "$FAKE_KEY"; do
    aws s3api delete-object --bucket "$ORIGINALS_BUCKET" --key "$key" >/dev/null 2>&1 || true
  done
  for key in "processed/$STAMP/prueba.webp" "thumbnails/$STAMP/prueba.webp"; do
    aws s3api delete-object --bucket "$PROCESSED_BUCKET" --key "$key" >/dev/null 2>&1 || true
  done
  rm -rf "$WORK"
}
trap cleanup_flow2 EXIT

if ! aws lambda get-function --function-name pinwatch-image-processor >/dev/null 2>&1; then
  fail "La Lambda pinwatch-image-processor no existe"
else
  # PNG de 1200x800 hecho a mano (la python3 del sistema no trae Pillow).
  python3 - "$WORK/prueba.png" <<'EOF'
import struct, sys, zlib
width, height = 1200, 800
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
rows = b"".join(
    b"\x00" + bytes(v for x in range(width) for v in (x * 255 // width, y * 255 // height, 160))
    for y in range(height)
)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
EOF
  printf 'no soy una imagen, aunque me llame .jpg\n' >"$WORK/falsa.jpg"

  start_ms="$(($(date +%s) * 1000 - 5000))"
  aws s3api put-object --bucket "$ORIGINALS_BUCKET" --key "$VALID_KEY" \
    --body "$WORK/prueba.png" --content-type image/png >/dev/null
  aws s3api put-object --bucket "$ORIGINALS_BUCKET" --key "$FAKE_KEY" \
    --body "$WORK/falsa.jpg" --content-type image/jpeg >/dev/null
  log "Subidos $VALID_KEY y $FAKE_KEY; esperando a la Lambda (hasta 90 s)"

  outputs=""
  for _ in $(seq 1 30); do
    if aws s3api head-object --bucket "$PROCESSED_BUCKET" --key "processed/$STAMP/prueba.webp" >/dev/null 2>&1 &&
      outputs="$(aws s3api head-object --bucket "$PROCESSED_BUCKET" --key "thumbnails/$STAMP/prueba.webp" \
        --query '[ContentType, ContentLength]' --output text 2>/dev/null | tr '\t' ' ')"; then
      break
    fi
    sleep 3
  done
  if [[ -n "$outputs" ]]; then
    pass "Imagen válida procesada: processed/ y thumbnails/ en $PROCESSED_BUCKET (miniatura: $outputs bytes)"
  else
    fail "No aparecieron processed/$STAMP/prueba.webp y thumbnails/$STAMP/prueba.webp"
  fi

  # CloudWatch tarda unos segundos en mostrar los logs.
  messages=""
  for _ in $(seq 1 30); do
    messages="$(aws logs filter-log-events --log-group-name "$LOG_GROUP" --start-time "$start_ms" \
      --filter-pattern "\"$STAMP\"" --query 'events[].message' --output text 2>/dev/null || true)"
    grep -q '"imagen_procesada"' <<<"$messages" && grep -q '"imagen_rechazada"' <<<"$messages" && break
    sleep 3
  done
  if grep -q '"imagen_procesada"' <<<"$messages"; then
    pass "Log en CloudWatch: imagen_procesada"
  else
    fail "No apareció imagen_procesada en $LOG_GROUP"
  fi
  if grep -q '"reason": "not_an_image"' <<<"$messages"; then
    pass "Archivo falso rechazado en el log (not_an_image), sin error de la Lambda"
  else
    fail "No apareció imagen_rechazada con not_an_image en $LOG_GROUP"
  fi
  if aws s3api head-object --bucket "$PROCESSED_BUCKET" --key "processed/$STAMP/falsa.webp" >/dev/null 2>&1; then
    fail "El archivo falso generó salida en processed/"
  else
    pass "El archivo falso no generó nada en $PROCESSED_BUCKET"
  fi

  # aws s3 ls y no s3api list-objects-v2: este último falla con la AWS CLI de apt sobre Python 3.14.
  count="$(aws s3 ls "s3://$ORIGINALS_BUCKET/originals/$STAMP/" | wc -l | tr -d ' ')"
  [[ "$count" == 2 ]] && pass "La Lambda no escribió en el bucket de originales" ||
    fail "Hay $count objetos en originals/$STAMP/ (se esperaban 2)"
fi

((FAILURES == 0)) || die "$FAILURES verificación(es) fallaron."
log "Todo funciona. Se borraron los archivos de prueba de ambos buckets."
