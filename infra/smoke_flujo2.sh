#!/usr/bin/env bash
# Prueba de humo del Flujo 2 después de un despliegue (la usa el CI/CD; también sirve a mano).
# Sube una imagen a originals/, espera la versión procesada y la miniatura, y borra todo lo de la prueba.
#   bash infra/smoke_flujo2.sh
# A diferencia de verify.sh, no revisa el bastión ni la RDS: solo que la Lambda desplegada funciona.
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INFRA_DIR/lib.sh"

aws_session

FUNCTION_NAME="pinwatch-image-processor"
ORIGINALS_BUCKET="${ORIGINALS_BUCKET:-pinwatch-originals-$ACCOUNT_ID}"
PROCESSED_BUCKET="${PROCESSED_BUCKET:-pinwatch-processed-$ACCOUNT_ID}"
STAMP="smoke-$(date +%s)-$RANDOM"
WORK="$(mktemp -d)"
ORIGINAL_KEY="originals/$STAMP/prueba.png"
PROCESSED_KEY="processed/$STAMP/prueba.webp"
THUMBNAIL_KEY="thumbnails/$STAMP/prueba.webp"
TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-90}"

cleanup() {
  aws s3api delete-object --bucket "$ORIGINALS_BUCKET" --key "$ORIGINAL_KEY" >/dev/null 2>&1 || true
  aws s3api delete-object --bucket "$PROCESSED_BUCKET" --key "$PROCESSED_KEY" >/dev/null 2>&1 || true
  aws s3api delete-object --bucket "$PROCESSED_BUCKET" --key "$THUMBNAIL_KEY" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

state="$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" \
  --query '[State, LastUpdateStatus]' --output text 2>/dev/null)" ||
  die "La Lambda $FUNCTION_NAME no existe."
[[ "$state" == $'Active\tSuccessful' ]] || die "La Lambda no está lista: $state"
log "Lambda $FUNCTION_NAME activa"

# PNG de 1200x800 hecho con la librería estándar (no hace falta Pillow).
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

aws s3api put-object --bucket "$ORIGINALS_BUCKET" --key "$ORIGINAL_KEY" \
  --body "$WORK/prueba.png" --content-type image/png >/dev/null
log "Subida s3://$ORIGINALS_BUCKET/$ORIGINAL_KEY; esperando a la Lambda (hasta $TIMEOUT_SECONDS s)"

deadline=$((SECONDS + TIMEOUT_SECONDS))
while ((SECONDS < deadline)); do
  if aws s3api head-object --bucket "$PROCESSED_BUCKET" --key "$PROCESSED_KEY" >/dev/null 2>&1 &&
    thumbnail="$(aws s3api head-object --bucket "$PROCESSED_BUCKET" --key "$THUMBNAIL_KEY" \
      --query '[ContentType, ContentLength]' --output text 2>/dev/null)"; then
    log "OK: $PROCESSED_KEY y $THUMBNAIL_KEY en $PROCESSED_BUCKET (miniatura: ${thumbnail//$'\t'/, } bytes)"
    exit 0
  fi
  sleep 3
done

warn "Últimas líneas del log de la Lambda:"
aws logs tail "/aws/lambda/$FUNCTION_NAME" --since 5m --format short 2>/dev/null | tail -n 20 >&2 || true
die "No aparecieron la imagen procesada y la miniatura en $TIMEOUT_SECONDS s."
