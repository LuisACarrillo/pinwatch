#!/usr/bin/env bash
# Genera tráfico real en PinWatch para poblar métricas, alarmas y widgets en CloudWatch.
#
#   bash infra/generate_metrics_traffic.sh
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INFRA_DIR/lib.sh"

aws_session

API_NAME="pinwatch-api"
API_FUNCTION="pinwatch-api"
IMAGE_FUNCTION="pinwatch-image-processor"
ORIGINALS_BUCKET="${ORIGINALS_BUCKET:-pinwatch-originals-$ACCOUNT_ID}"

log "Buscando endpoint de API Gateway..."
api_id="$(aws apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId | [0]" --output text 2>/dev/null | grep -v '^None$' || true)"

if [[ -z "$api_id" ]]; then
  die "No se encontró API Gateway '$API_NAME'. Asegúrate de haber ejecutado 'bash infra/api.sh up'."
fi

API_URL="$(aws apigatewayv2 get-api --api-id "$api_id" --query ApiEndpoint --output text)"
log "Endpoint detectado: $API_URL"

# 1. Tráfico general para Latencia / Duration (Métrica 1)
log "1/4 Generando peticiones a la API (Métrica 1: Latencia / Duration)..."
for i in {1..5}; do
  curl -s -o /dev/null -w "%{http_code}\n" "$API_URL/health" || true
done
log "Peticiones a /health completadas."

# 2. Actividad de Negocio Flujo 3 (Métrica 3: Tableros, Pines y Likes)
log "2/4 Generando actividad de negocio Flujo 3 (Métrica 3: Tableros, Pines y Likes)..."
STAMP="$(date +%s)-$RANDOM"
USER="dario_$STAMP"
EMAIL="dario_$STAMP@example.com"
PASSWORD="Password123!"

# Registro de usuario
reg_response="$(curl -s -X POST "$API_URL/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"$USER\", \"email\": \"$EMAIL\", \"password\": \"$PASSWORD\"}")"

token="$(python3 -c 'import json, sys; res = json.loads(sys.argv[1]); print(res.get("token", ""))' "$reg_response")"

if [[ -z "$token" ]]; then
  warn "No se pudo obtener token de autenticación. Respuesta: $reg_response"
else
  log "Usuario registrado y autenticado: $USER"

  # Crear tablero (evento board_created)
  board_res="$(curl -s -X POST "$API_URL/boards" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"Tablero CloudWatch $STAMP\", \"description\": \"Tablero de prueba de métricas\"}")"
  board_id="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("id", ""))' "$board_res")"
  log "Tablero creado exitosamente (board_id: $board_id)"

  # Crear pin (evento pin_created)
  pin_res="$(curl -s -X POST "$API_URL/pins" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"title\": \"Pin de Monitoreo $STAMP\", \"category\": \"cloud\", \"object_key\": \"originals/traffic-$STAMP/img.jpg\"}")"
  pin_id="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("id", ""))' "$pin_res")"
  log "Pin creado exitosamente (pin_id: $pin_id)"

  # Registrar like (evento like_registered)
  if [[ -n "$pin_id" ]]; then
    like_res="$(curl -s -X POST "$API_URL/pins/$pin_id/like" \
      -H "Authorization: Bearer $token")"
    log "Like registrado exitosamente en el pin $pin_id"
  fi

  # Agregar pin a tablero (evento board_pin_added)
  if [[ -n "$board_id" && -n "$pin_id" ]]; then
    curl -s -X POST "$API_URL/boards/$board_id/pins" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "{\"pin_id\": \"$pin_id\"}" >/dev/null || true
    log "Pin agregado al tablero."
  fi
fi

# 3. Procesamiento de imágenes (Métrica 4) y Objetos S3 (Métrica 5)
log "3/4 Ejecutando prueba de imagen en S3 (Métrica 4: Imágenes procesadas y Métrica 5: S3)..."
if [[ -f "$INFRA_DIR/smoke_flujo2.sh" ]]; then
  bash "$INFRA_DIR/smoke_flujo2.sh" || warn "smoke_flujo2.sh reportó aviso o tardó; ver logs de S3/Lambda."
else
  # Subir imagen mínima a S3 originals
  TMP_IMG="$(mktemp --suffix=.png 2>/dev/null || mktemp)"
  python3 -c '
import struct, sys, zlib
width, height = 100, 100
chunk = lambda tag, data: struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
rows = b"".join(b"\x00" + b"\xff\x00\x00" * width for _ in range(height))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
' "$TMP_IMG"
  aws s3 cp "$TMP_IMG" "s3://$ORIGINALS_BUCKET/originals/traffic-$STAMP/sample.png" >/dev/null
  rm -f "$TMP_IMG"
  log "Imagen subida a s3://$ORIGINALS_BUCKET/originals/traffic-$STAMP/sample.png para procesar."
fi

# 4. Error provocado para Métrica 2 (Errores API Lambda)
log "4/4 Generando error controlado de prueba (Métrica 2: ApiErrors)..."
curl -s -X POST "$API_URL/boards/board-inexistente-error/pins" \
  -H "Authorization: Bearer ${token:-invalido}" \
  -H "Content-Type: application/json" \
  -d '{"pin_id": "none"}' >/dev/null || true
log "Error simulado enviado."

log "¡Listo! El tráfico ha sido emitido. En CloudWatch toma entre 1 y 2 minutos reflejar las métricas en las gráficas."
