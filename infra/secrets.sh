#!/usr/bin/env bash
# Secretos de PinWatch en AWS Secrets Manager.
#   infra/secrets.sh up       crea el secreto de JWT o reusa el que ya existe
#   infra/secrets.sh status   muestra el secreto (sin su valor)
#   infra/secrets.sh down     lo borra sin periodo de recuperación
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JWT_SECRET_NAME="${JWT_SECRET_NAME:-pinwatch/jwt}"

# Imprime "ARN<TAB>DeletedDate" o nada si el secreto no existe.
describe_secret() {
  aws secretsmanager describe-secret --secret-id "$1" \
    --query '[ARN, DeletedDate]' --output text 2>/dev/null || true
}

secrets_up() {
  require_cmd openssl
  local info arn deleted
  info="$(describe_secret "$JWT_SECRET_NAME")"

  if [[ -n "$info" ]]; then
    read -r arn deleted <<<"$info"
    if [[ "$deleted" != "None" ]]; then
      log "El secreto $JWT_SECRET_NAME estaba programado para borrarse; se restaura."
      aws secretsmanager restore-secret --secret-id "$JWT_SECRET_NAME" >/dev/null
    fi
    # No se rota la llave: hacerlo invalidaría los tokens emitidos.
    log "Secreto existente reutilizado: $arn"
    return
  fi

  log "Creando el secreto $JWT_SECRET_NAME con una llave de firma aleatoria"
  # El valor viaja en un archivo temporal (0600) y no en la línea de comandos, donde lo vería `ps`.
  secret_file="$(mktemp)"
  trap 'rm -f "${secret_file:-}"' EXIT
  printf '{"jwt_signing_key":"%s","jwt_algorithm":"HS256"}' "$(openssl rand -hex 64)" >"$secret_file"

  arn="$(aws secretsmanager create-secret \
    --name "$JWT_SECRET_NAME" \
    --description "Llave de firma de los JWT de PinWatch" \
    --secret-string "file://$secret_file" \
    --tags "Key=Project,Value=$PROJECT_TAG" "Key=Owner,Value=$OWNER_TAG" \
    --query ARN --output text)"
  log "Secreto creado: $arn"
}

secrets_status() {
  local info
  info="$(describe_secret "$JWT_SECRET_NAME")"
  if [[ -z "$info" ]]; then
    log "$JWT_SECRET_NAME: no existe"
  else
    log "$JWT_SECRET_NAME: $info"
  fi
}

secrets_down() {
  if [[ -z "$(describe_secret "$JWT_SECRET_NAME")" ]]; then
    log "$JWT_SECRET_NAME no existe; nada que borrar."
    return
  fi
  confirm "¿Borrar el secreto $JWT_SECRET_NAME sin recuperación?" || die "Cancelado."
  aws secretsmanager delete-secret --secret-id "$JWT_SECRET_NAME" \
    --force-delete-without-recovery >/dev/null
  log "Secreto $JWT_SECRET_NAME borrado."
}

parse_args "$@"
aws_session
"secrets_$ACTION"
