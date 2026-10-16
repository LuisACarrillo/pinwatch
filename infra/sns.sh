#!/usr/bin/env bash
# Tópico de Amazon SNS para notificaciones asíncronas de eventos en PinWatch.
#   infra/sns.sh up       crea el tópico en SNS y registra sns_topic_arn en Secrets Manager
#   infra/sns.sh status   muestra el estado y ARN del tópico SNS
#   infra/sns.sh down     elimina el tópico y remueve la llave del secreto
#
# Configuración sensible y ARN se registran automáticamente en Secrets Manager (pinwatch/app).
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INFRA_DIR/lib.sh"

SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-pinwatch-events}"
APP_SECRET_NAME="${APP_SECRET_NAME:-pinwatch/app}"

find_topic_arn() {
  aws sns list-topics \
    --query "Topics[?ends_with(TopicArn, ':$SNS_TOPIC_NAME')].TopicArn" \
    --output text 2>/dev/null | grep -v '^None$' || true
}

update_app_secret() {
  local topic_arn="$1"
  require_cmd python3

  local current desired
  current="$(mktemp)"
  desired="$(mktemp)"
  trap 'rm -f "${current:-}" "${desired:-}"' EXIT

  if aws secretsmanager get-secret-value --secret-id "$APP_SECRET_NAME" \
    --query SecretString --output text >"$current" 2>/dev/null; then
    TOPIC_ARN="$topic_arn" python3 -c '
import json, os, sys
secret = json.load(sys.stdin)
secret["sns_topic_arn"] = os.environ["TOPIC_ARN"]
json.dump(secret, open(sys.argv[1], "w"))
' "$desired" <"$current"

    aws secretsmanager put-secret-value --secret-id "$APP_SECRET_NAME" \
      --secret-string "file://$desired" >/dev/null
    log "Secreto $APP_SECRET_NAME actualizado con sns_topic_arn."
  else
    warn "No existe el secreto $APP_SECRET_NAME. Ejecuta 'bash infra/secrets.sh up' primero para crearlo."
  fi
}

remove_from_app_secret() {
  require_cmd python3

  local current desired
  current="$(mktemp)"
  desired="$(mktemp)"
  trap 'rm -f "${current:-}" "${desired:-}"' EXIT

  if aws secretsmanager get-secret-value --secret-id "$APP_SECRET_NAME" \
    --query SecretString --output text >"$current" 2>/dev/null; then
    python3 -c '
import json, sys
secret = json.load(sys.stdin)
if "sns_topic_arn" in secret:
    del secret["sns_topic_arn"]
json.dump(secret, open(sys.argv[1], "w"))
' "$desired" <"$current"

    aws secretsmanager put-secret-value --secret-id "$APP_SECRET_NAME" \
      --secret-string "file://$desired" >/dev/null
    log "sns_topic_arn removido del secreto $APP_SECRET_NAME."
  fi
}

sns_up() {
  log "Creando o verificando tópico Amazon SNS '$SNS_TOPIC_NAME'..."
  local arn
  arn="$(aws sns create-topic \
    --name "$SNS_TOPIC_NAME" \
    --tags "Key=Project,Value=$PROJECT_TAG" "Key=Owner,Value=$OWNER_TAG" "Key=Name,Value=$SNS_TOPIC_NAME" \
    --query TopicArn --output text)"

  log "Tópico SNS listo: $arn"
  update_app_secret "$arn"
}

sns_status() {
  local arn
  arn="$(find_topic_arn)"
  if [[ -n "$arn" ]]; then
    log "Tópico SNS '$SNS_TOPIC_NAME' existe: $arn"
  else
    log "Tópico SNS '$SNS_TOPIC_NAME': no existe."
  fi
}

sns_down() {
  local arn
  arn="$(find_topic_arn)"
  if [[ -z "$arn" ]]; then
    log "El tópico SNS '$SNS_TOPIC_NAME' no existe; nada que borrar."
    return
  fi

  confirm "¿Eliminar el tópico SNS '$SNS_TOPIC_NAME' ($arn)?" || die "Cancelado."
  aws sns delete-topic --topic-arn "$arn" >/dev/null
  log "Tópico SNS '$arn' eliminado."
  remove_from_app_secret
}

parse_args "$@"
aws_session
"sns_$ACTION"
