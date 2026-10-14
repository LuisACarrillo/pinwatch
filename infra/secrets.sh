#!/usr/bin/env bash
# Secreto de configuración de PinWatch en AWS Secrets Manager.
#   infra/secrets.sh up       crea el secreto o completa las llaves que le falten
#   infra/secrets.sh status   muestra el secreto y sus llaves (sin valores)
#   infra/secrets.sh down     lo borra sin periodo de recuperación
#
# El secreto es un JSON. Este script solo genera jwt_signing_key y jwt_algorithm;
# las llaves db_* las agrega quien crea la base de datos y up nunca las pisa.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP_SECRET_NAME="${APP_SECRET_NAME:-pinwatch/app}"

# Imprime "ARN<TAB>DeletedDate" o nada si el secreto no existe.
describe_secret() {
  aws secretsmanager describe-secret --secret-id "$1" \
    --query '[ARN, DeletedDate]' --output text 2>/dev/null || true
}

# Lee un JSON por stdin y le agrega las llaves por defecto que no tenga.
fill_defaults() {
  JWT_KEY="$(openssl rand -hex 64)" python3 -c '
import json, os, sys
secret = json.load(sys.stdin)
secret.setdefault("jwt_signing_key", os.environ["JWT_KEY"])
secret.setdefault("jwt_algorithm", "HS256")
json.dump(secret, sys.stdout)
'
}

secrets_up() {
  require_cmd openssl
  require_cmd python3
  # El valor viaja en archivos temporales (0600) y no en la línea de comandos, donde lo vería `ps`.
  local current desired
  current="$(mktemp)"
  desired="$(mktemp)"
  trap 'rm -f "${current:-}" "${desired:-}"' EXIT

  # Tras un borrado forzado, el secreto sigue apareciendo con DeletedDate unos segundos:
  # no se puede restaurar ni crear otro con el mismo nombre. Se espera hasta que se resuelva.
  local info arn deleted output attempt ready=0
  for attempt in $(seq 1 12); do
    info="$(describe_secret "$APP_SECRET_NAME")"
    if [[ -z "$info" ]]; then
      printf '{}' | fill_defaults >"$desired"
      if output="$(aws secretsmanager create-secret \
        --name "$APP_SECRET_NAME" \
        --description "Configuración sensible de PinWatch: llave JWT y conexión a la base" \
        --secret-string "file://$desired" \
        --tags "Key=Project,Value=$PROJECT_TAG" "Key=Owner,Value=$OWNER_TAG" \
        --query ARN --output text 2>&1)"; then
        log "Secreto creado con una llave de firma JWT aleatoria: $output"
        return
      fi
      [[ "$output" == *"scheduled for deletion"* ]] || die "$output"
    else
      read -r arn deleted <<<"$info"
      if [[ "$deleted" == "None" ]]; then
        ready=1
        break
      fi
      if aws secretsmanager restore-secret --secret-id "$APP_SECRET_NAME" >/dev/null 2>&1; then
        log "El secreto estaba programado para borrarse; se restauró."
        ready=1
        break
      fi
    fi
    log "El nombre $APP_SECRET_NAME está ocupado por un borrado reciente; reintento en 5 s ($attempt/12)"
    sleep 5
  done
  ((ready)) || die "El nombre $APP_SECRET_NAME sigue ocupado. Espera un minuto y repite."

  aws secretsmanager get-secret-value --secret-id "$APP_SECRET_NAME" \
    --query SecretString --output text >"$current"
  fill_defaults <"$current" >"$desired"
  if python3 -c 'import json, sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))' \
    "$current" "$desired"; then
    # No se rota la llave existente: hacerlo invalidaría los tokens emitidos.
    log "Secreto existente reutilizado sin cambios: $arn"
  else
    aws secretsmanager put-secret-value --secret-id "$APP_SECRET_NAME" \
      --secret-string "file://$desired" >/dev/null
    log "Secreto existente completado con las llaves que faltaban: $arn"
  fi
}

secrets_status() {
  local info keys
  info="$(describe_secret "$APP_SECRET_NAME")"
  if [[ -z "$info" ]]; then
    log "$APP_SECRET_NAME: no existe"
    return
  fi
  keys="$(aws secretsmanager get-secret-value --secret-id "$APP_SECRET_NAME" \
    --query SecretString --output text 2>/dev/null |
    python3 -c 'import json, sys; print(", ".join(sorted(json.load(sys.stdin))))' 2>/dev/null ||
    echo "no se pudo leer")"
  log "$APP_SECRET_NAME: $info"
  log "Llaves: $keys"
}

secrets_down() {
  if [[ -z "$(describe_secret "$APP_SECRET_NAME")" ]]; then
    log "$APP_SECRET_NAME no existe; nada que borrar."
    return
  fi
  confirm "¿Borrar el secreto $APP_SECRET_NAME sin recuperación?" || die "Cancelado."
  aws secretsmanager delete-secret --secret-id "$APP_SECRET_NAME" \
    --force-delete-without-recovery >/dev/null
  log "Secreto $APP_SECRET_NAME borrado."
}

parse_args "$@"
aws_session
"secrets_$ACTION"
