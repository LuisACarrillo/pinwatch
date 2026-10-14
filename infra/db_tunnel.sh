#!/usr/bin/env bash
# Túnel de Session Manager desde tu máquina hasta la base RDS, pasando por el bastión.
# No abre puertos ni usa SSH. Deja la terminal abierta mientras lo usas; Ctrl+C lo cierra.
#   bash infra/db_tunnel.sh                       host y puerto salen de pinwatch/app (db_host, db_port)
#   bash infra/db_tunnel.sh <host> [puerto] [puerto-local]
# Luego, en otra terminal:
#   psql -h localhost -p 15432 -U <usuario> <base>
#
# Requiere session-manager-plugin y que el security group de la RDS acepte el puerto
# desde el security group pinwatch-bastion-sg.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP_SECRET_NAME="${APP_SECRET_NAME:-pinwatch/app}"

require_cmd session-manager-plugin
aws_session

secret_value() {
  aws secretsmanager get-secret-value --secret-id "$APP_SECRET_NAME" \
    --query SecretString --output text 2>/dev/null |
    python3 -c 'import json, sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1" 2>/dev/null || true
}

HOST="${1:-$(secret_value db_host)}"
REMOTE_PORT="${2:-$(secret_value db_port)}"
REMOTE_PORT="${REMOTE_PORT:-5432}"
# 15432 por defecto para no chocar con un PostgreSQL local en el 5432.
LOCAL_PORT="${3:-15432}"
[[ -n "$HOST" ]] || die "No hay host. Pásalo como argumento o agrega db_host a $APP_SECRET_NAME."

INSTANCE_ID="$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=pinwatch-bastion" "Name=tag:Project,Values=$PROJECT_TAG" \
  "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
[[ "$INSTANCE_ID" != "None" ]] ||
  die "El bastión no está en running. Arráncalo con: bash infra/ec2.sh up"

log "Túnel localhost:$LOCAL_PORT -> $HOST:$REMOTE_PORT a través de $INSTANCE_ID"
exec aws ssm start-session --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$HOST\"],\"portNumber\":[\"$REMOTE_PORT\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}"
