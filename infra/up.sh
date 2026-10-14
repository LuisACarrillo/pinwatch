#!/usr/bin/env bash
# Levanta toda la infraestructura de Luis Fernando, en orden. Se puede correr las veces que haga falta.
#   infra/up.sh
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INFRA_DIR/lib.sh"

aws_session

log "1/2 Secrets Manager"
bash "$INFRA_DIR/secrets.sh" up
log "2/2 EC2 de servicios auxiliares"
bash "$INFRA_DIR/ec2.sh" up

log "Todo arriba. Revisa el estado con: bash infra/teardown.sh --status"
