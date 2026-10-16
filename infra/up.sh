#!/usr/bin/env bash
# Levanta toda la infraestructura de PinWatch, en orden. Se puede correr las veces que haga falta.
#   infra/up.sh
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INFRA_DIR/lib.sh"

aws_session

# Orden: el secreto primero (SNS y RDS escriben en él), el bastión antes que la RDS
# (rds.sh abre el 5432 a su security group y aplica schema.sql a través de él).
log "1/5 Secrets Manager"
bash "$INFRA_DIR/secrets.sh" up
log "2/5 Amazon SNS (pinwatch-events)"
bash "$INFRA_DIR/sns.sh" up
log "3/5 Bastión EC2"
bash "$INFRA_DIR/ec2.sh" up
log "4/5 Base de datos Amazon RDS"
bash "$INFRA_DIR/rds.sh" up
log "5/5 Flujo 2: procesamiento de imágenes"
bash "$INFRA_DIR/image_processor.sh" up

log "Todo arriba. Compruébalo con: bash infra/verify.sh"
