#!/usr/bin/env bash
# Baja todo lo que crean los scripts de Luis Fernando, en orden inverso a up.sh.
# No toca el bucket de originales ni la base de datos RDS.
#   infra/teardown.sh           pide confirmación
#   infra/teardown.sh --yes     sin preguntar
#   infra/teardown.sh --status  solo muestra qué existe
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INFRA_DIR/lib.sh"

MODE="down"
for arg in "$@"; do
  case "$arg" in
    -y | --yes) ASSUME_YES=1 ;;
    --status) MODE="status" ;;
    *) die "Argumento desconocido: $arg. Uso: $(basename "$0") [--yes | --status]" ;;
  esac
done
ASSUME_YES="${ASSUME_YES:-0}"

aws_session

bash "$INFRA_DIR/rds.sh" status
bash "$INFRA_DIR/ec2.sh" status
bash "$INFRA_DIR/sns.sh" status
bash "$INFRA_DIR/secrets.sh" status
[[ "$MODE" == "status" ]] && exit 0

confirm "Se borrará todo lo anterior en la cuenta $ACCOUNT_ID. ¿Continuar?" || die "Cancelado."

# Orden: primero RDS y bastión (con sus security groups), luego SNS y al final los secretos.
log "1/4 Base de datos Amazon RDS"
bash "$INFRA_DIR/rds.sh" down --yes
log "2/4 Bastión EC2"
bash "$INFRA_DIR/ec2.sh" down --yes
log "3/4 Amazon SNS"
bash "$INFRA_DIR/sns.sh" down --yes
log "4/4 Secrets Manager"
bash "$INFRA_DIR/secrets.sh" down --yes

log "Teardown terminado."


