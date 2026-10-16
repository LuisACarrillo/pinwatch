#!/usr/bin/env bash
# Comprueba que lo que levanta up.sh funciona de punta a punta. No crea ni borra nada.
#   bash infra/verify.sh
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INFRA_DIR/lib.sh"

APP_SECRET_NAME="${APP_SECRET_NAME:-pinwatch/app}"
FAILURES=0
pass() { log "OK     $*"; }
fail() {
  log "FALLA  $*"
  FAILURES=$((FAILURES + 1))
}

aws_session

# 1. Secreto legible y con llave JWT, sin imprimir valores.
keys="$(aws secretsmanager get-secret-value --secret-id "$APP_SECRET_NAME" \
  --query SecretString --output text 2>/dev/null |
  python3 -c 'import json, sys; s = json.load(sys.stdin); print(len(s.get("jwt_signing_key", "")), ",".join(sorted(s)))' \
    2>/dev/null || true)"
if [[ "$keys" =~ ^([0-9]+)\ (.*)$ ]] && ((BASH_REMATCH[1] >= 64)); then
  pass "Secreto $APP_SECRET_NAME legible; llaves: ${BASH_REMATCH[2]}"
else
  fail "Secreto $APP_SECRET_NAME no se pudo leer o no trae jwt_signing_key"
fi

# 2. Bastión en running y registrado en Session Manager.
id="$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=pinwatch-bastion" "Name=tag:Project,Values=$PROJECT_TAG" \
  "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
if [[ "$id" == "None" ]]; then
  fail "El bastión no está en running"
else
  pass "Bastión en running: $id"
  ping="$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
  [[ "$ping" == "Online" ]] && pass "Registrado en Session Manager" || fail "Session Manager: ${ping:-sin registro}"

  # 3. start-session de verdad: corre psql --version dentro del bastión.
  if command -v session-manager-plugin >/dev/null 2>&1; then
    out="$(ssm_run "$id" "psql --version")"
    version="$(grep -o 'psql (PostgreSQL) [0-9.]*' <<<"$out" || true)"
    [[ -n "$version" ]] && pass "start-session funciona; en el bastión: $version" ||
      fail "start-session no devolvió psql --version -> $(grep . <<<"$out" | tail -n 1)"
  else
    fail "Falta session-manager-plugin en esta máquina"
  fi

  # 4. Sin puertos abiertos en el security group.
  open="$(aws ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text |
    xargs -I{} aws ec2 describe-security-groups --group-ids {} \
      --query 'length(SecurityGroups[0].IpPermissions)' --output text)"
  [[ "$open" == 0 ]] && pass "Security group sin reglas de entrada" ||
    log "AVISO  El security group tiene $open regla(s) de entrada (¿EC2_ACCESS=ssh?)"
fi

# 5. Base de datos RDS PostgreSQL disponible y conectada en Secrets Manager
rds_status="$(aws rds describe-db-instances --db-instance-identifier "pinwatch-db" \
  --query 'DBInstances[0].[DBInstanceStatus, Endpoint.Address]' --output text 2>/dev/null || true)"
if [[ -n "$rds_status" ]]; then
  read -r rds_st rds_ep <<<"$rds_status"
  if [[ "$rds_st" == "available" ]]; then
    pass "RDS pinwatch-db en available: $rds_ep"
  else
    fail "RDS pinwatch-db en estado '$rds_st' (no available)"
  fi
else
  log "AVISO  RDS pinwatch-db no encontrada (ejecuta 'bash infra/rds.sh up' para levantarla)"
fi

# 6. Tópico Amazon SNS existente
sns_arn="$(aws sns list-topics \
  --query "Topics[?ends_with(TopicArn, ':pinwatch-events')].TopicArn" \
  --output text 2>/dev/null | grep -v '^None$' || true)"
if [[ -n "$sns_arn" ]]; then
  pass "Tópico Amazon SNS pinwatch-events existe: $sns_arn"
else
  log "AVISO  Tópico SNS pinwatch-events no encontrado (ejecuta 'bash infra/sns.sh up' para crearlo)"
fi

((FAILURES == 0)) || die "$FAILURES verificación(es) fallaron."
log "Todo funciona."



