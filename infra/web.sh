#!/usr/bin/env bash
# Publica el frontend de PinWatch como sitio estático en S3, apuntando a la API de infra/api.sh.
#
#   infra/web.sh up       construye el frontend con la URL de la API y lo sube
#   infra/web.sh status   muestra el bucket y la URL del sitio
#   infra/web.sh down     vacía y borra el bucket del sitio
#
# El sitio queda en HTTP (el hosting de S3 no sirve HTTPS). La API sí es HTTPS;
# el navegador permite esa combinación.
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$INFRA_DIR")"
source "$INFRA_DIR/lib.sh"

API_NAME="pinwatch-api"

set_names() {
  WEB_BUCKET="${WEB_BUCKET:-pinwatch-web-$ACCOUNT_ID}"
  WEB_ORIGIN="http://${WEB_BUCKET}.s3-website-${AWS_REGION}.amazonaws.com"
  ORIGINALS_BUCKET="${ORIGINALS_BUCKET:-pinwatch-originals-$ACCOUNT_ID}"
}

bucket_exists() { aws s3api head-bucket --bucket "$1" >/dev/null 2>&1; }

find_api_endpoint() {
  local api_id
  api_id="$(aws apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId | [0]" \
    --output text 2>/dev/null | grep -v '^None$' || true)"
  [[ -n "$api_id" ]] || die "No existe la API $API_NAME. Corre antes: bash infra/api.sh up"
  aws apigatewayv2 get-api --api-id "$api_id" --query ApiEndpoint --output text
}

build_frontend() {
  local api_url="$1"
  if [[ -n "${SKIP_WEB_BUILD:-}" && -d "$REPO_DIR/frontend/dist" ]]; then
    log "SKIP_WEB_BUILD=1: se reutiliza frontend/dist. Tiene que haberse construido con VITE_API_URL=$api_url"
    return
  fi
  log "Construyendo el frontend con VITE_API_URL=$api_url"
  if command -v node >/dev/null 2>&1 && command -v pnpm >/dev/null 2>&1; then
    (cd "$REPO_DIR" && VITE_API_URL="$api_url" pnpm build)
  elif command -v cmd.exe >/dev/null 2>&1; then
    # En WSL, pnpm de Windows busca `node` y no lo encuentra. cmd.exe sí tiene el PATH de Windows.
    (cd "$REPO_DIR" && cmd.exe /c "set VITE_API_URL=${api_url}&& pnpm build")
  else
    die "No está pnpm. Instálalo en esta sesión o construye frontend/dist y repite con SKIP_WEB_BUILD=1."
  fi
  [[ -f "$REPO_DIR/frontend/dist/index.html" ]] || die "El build no dejó frontend/dist/index.html."
}

allow_browser_upload() {
  local cors
  cors="$(mktemp)"
  WEB_ORIGIN="$WEB_ORIGIN" python3 -c 'import json, os, sys; json.dump({"CORSRules": [{"AllowedOrigins": ["http://localhost:5173", "http://127.0.0.1:5173", os.environ["WEB_ORIGIN"]], "AllowedMethods": ["PUT", "GET", "HEAD"], "AllowedHeaders": ["content-type", "x-amz-*"], "ExposeHeaders": ["ETag"], "MaxAgeSeconds": 3600}]}, sys.stdout)' >"$cors"
  if bucket_exists "$ORIGINALS_BUCKET"; then
    aws s3api put-bucket-cors --bucket "$ORIGINALS_BUCKET" --cors-configuration "file://$cors"
    log "CORS de $ORIGINALS_BUCKET acepta subidas desde $WEB_ORIGIN"
  else
    warn "No existe $ORIGINALS_BUCKET; el formulario no podrá subir imágenes hasta crearlo."
  fi
  rm -f "$cors"
}

web_up() {
  require_cmd python3
  set_names
  local api_url policy
  api_url="$(find_api_endpoint)"
  build_frontend "$api_url"

  if bucket_exists "$WEB_BUCKET"; then
    log "Bucket del sitio existente: $WEB_BUCKET"
  else
    aws s3api create-bucket --bucket "$WEB_BUCKET" >/dev/null
    log "Bucket del sitio creado: $WEB_BUCKET"
  fi
  aws s3api put-public-access-block --bucket "$WEB_BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"
  aws s3api put-bucket-tagging --bucket "$WEB_BUCKET" \
    --tagging "TagSet=[{Key=Project,Value=$PROJECT_TAG},{Key=Owner,Value=$OWNER_TAG}]"
  aws s3api put-bucket-website --bucket "$WEB_BUCKET" \
    --website-configuration '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"index.html"}}'

  policy="$(mktemp)"
  WEB_BUCKET="$WEB_BUCKET" python3 -c 'import json, os, sys; bucket = os.environ["WEB_BUCKET"]; json.dump({"Version": "2012-10-17", "Statement": [{"Sid": "PublicReadGetObject", "Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Resource": f"arn:aws:s3:::{bucket}/*"}]}, sys.stdout)' >"$policy"
  aws s3api put-bucket-policy --bucket "$WEB_BUCKET" --policy "file://$policy"
  rm -f "$policy"

  aws s3 sync "$REPO_DIR/frontend/dist" "s3://$WEB_BUCKET" --delete --only-show-errors
  allow_browser_upload
  log "Sitio listo: $WEB_ORIGIN"
  log "Habla con la API en $api_url"
}

web_status() {
  set_names
  if bucket_exists "$WEB_BUCKET"; then
    log "$WEB_BUCKET: $WEB_ORIGIN"
  else
    log "$WEB_BUCKET: no existe"
  fi
}

web_down() {
  set_names
  if ! bucket_exists "$WEB_BUCKET"; then
    log "El bucket $WEB_BUCKET no existe; nada que borrar."
    return
  fi
  confirm "¿Vaciar y borrar el sitio $WEB_BUCKET?" || die "Cancelado."
  aws s3 rm "s3://$WEB_BUCKET" --recursive --only-show-errors
  aws s3api delete-bucket --bucket "$WEB_BUCKET"
  log "Bucket $WEB_BUCKET borrado."
}

parse_args "$@"
aws_session
"web_$ACTION"
