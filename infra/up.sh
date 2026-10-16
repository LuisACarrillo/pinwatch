#!/usr/bin/env bash
# Levanta toda la infraestructura de Luis Fernando, en orden. Se puede correr las veces que haga falta.
#   infra/up.sh
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INFRA_DIR/lib.sh"

aws_session

log "1/3 Secrets Manager"
bash "$INFRA_DIR/secrets.sh" up
log "2/3 Bastión EC2"
bash "$INFRA_DIR/ec2.sh" up
log "3/3 Base de datos Amazon RDS"
bash "$INFRA_DIR/rds.sh" up

log "Todo arriba. Compruébalo con: bash infra/verify.sh"

