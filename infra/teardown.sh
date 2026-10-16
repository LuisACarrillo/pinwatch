#!/usr/bin/env bash
# Baja todo lo que crean los scripts de Luis Fernando, en orden inverso a up.sh.
# No toca el bucket de originales (solo retira de él la notificación del Flujo 2) ni la base RDS.
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
bash "$INFRA_DIR/ec2.sh" status
bash "$INFRA_DIR/secrets.sh" status
[[ "$MODE" == "status" ]] && exit 0

confirm "Se borrará todo lo anterior en la cuenta $ACCOUNT_ID. ¿Continuar?" || die "Cancelado."

# Orden: primero lo que depende de otros recursos. La notificación de S3 antes que la Lambda,
# la instancia antes que su security group y al final los secretos.
log "1/3 Flujo 2: notificación, Lambda, logs y bucket processed"
bash "$INFRA_DIR/image_processor.sh" down --yes
log "2/3 Bastión EC2"
bash "$INFRA_DIR/ec2.sh" down --yes
log "3/3 Secrets Manager"
bash "$INFRA_DIR/secrets.sh" down --yes

log "Teardown terminado."
