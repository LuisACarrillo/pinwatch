#!/usr/bin/env bash
# Baja todo lo que crean los scripts de infra/, en orden inverso a up.sh.
# Borra la RDS sin snapshot final. No borra el bucket de originales (solo retira de él la
# notificación del Flujo 2).
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

bash "$INFRA_DIR/image_processor.sh" status
bash "$INFRA_DIR/rds.sh" status
bash "$INFRA_DIR/ec2.sh" status
bash "$INFRA_DIR/sns.sh" status
bash "$INFRA_DIR/secrets.sh" status
[[ "$MODE" == "status" ]] && exit 0

confirm "Se borrará todo lo anterior en la cuenta $ACCOUNT_ID. ¿Continuar?" || die "Cancelado."

# Orden: primero lo que depende de otros recursos. La notificación de S3 antes que la Lambda;
# la RDS antes que el bastión (su security group referencia al del bastión); SNS y al final
# los secretos, de los que leen todos los demás.
log "1/5 Flujo 2: notificación, Lambda, logs y bucket processed"
bash "$INFRA_DIR/image_processor.sh" down --yes
log "2/5 Base de datos Amazon RDS"
bash "$INFRA_DIR/rds.sh" down --yes
log "3/5 Bastión EC2"
bash "$INFRA_DIR/ec2.sh" down --yes
log "4/5 Amazon SNS"
bash "$INFRA_DIR/sns.sh" down --yes
log "5/5 Secrets Manager"
bash "$INFRA_DIR/secrets.sh" down --yes

log "Teardown terminado."
