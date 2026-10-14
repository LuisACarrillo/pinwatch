#!/usr/bin/env bash
# Verifica que la sesión del Learner Lab permita lo que usan los scripts de infra/.
# No deja nada creado: el secreto de prueba se borra al terminar, pase lo que pase.
#   infra/check_lab.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FAILURES=0
pass() { log "OK     $*"; }
fail() {
  log "FALLA  $*"
  FAILURES=$((FAILURES + 1))
}

# Corre una prueba: check "descripción" comando...
check() {
  local description="$1" output
  shift
  if output="$("$@" 2>&1)"; then
    pass "$description${output:+ -> $output}"
  else
    fail "$description -> $(tail -n 1 <<<"$output")"
  fi
}

aws_session

check "LabRole existe" \
  aws iam get-role --role-name LabRole --query Role.Arn --output text
check "LabInstanceProfile existe" \
  aws iam get-instance-profile --instance-profile-name LabInstanceProfile \
  --query 'InstanceProfile.Roles[0].RoleName' --output text
check "Key pair vockey existe" \
  aws ec2 describe-key-pairs --key-names vockey --query 'KeyPairs[0].KeyName' --output text
check "VPC default" \
  aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text
check "AMI de Amazon Linux 2023 desde SSM" \
  aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text

# Secrets Manager: crear, leer y borrar un secreto de prueba con nombre único.
SMOKE_NAME="pinwatch/smoke-test-$(date +%s)"
SMOKE_VALUE="ok-$RANDOM"
cleanup() {
  aws secretsmanager delete-secret --secret-id "$SMOKE_NAME" \
    --force-delete-without-recovery >/dev/null 2>&1 || true
}
trap cleanup EXIT

check "Secrets Manager: crear $SMOKE_NAME" \
  aws secretsmanager create-secret --name "$SMOKE_NAME" --secret-string "$SMOKE_VALUE" \
  --tags "Key=Project,Value=$PROJECT_TAG" "Key=Owner,Value=$OWNER_TAG" --query Name --output text
read_back="$(aws secretsmanager get-secret-value --secret-id "$SMOKE_NAME" \
  --query SecretString --output text 2>&1 || true)"
if [[ "$read_back" == "$SMOKE_VALUE" ]]; then
  pass "Secrets Manager: leer el valor (coincide)"
else
  fail "Secrets Manager: leer el valor -> $(tail -n 1 <<<"$read_back")"
fi
check "Secrets Manager: borrar sin recuperación" \
  aws secretsmanager delete-secret --secret-id "$SMOKE_NAME" --force-delete-without-recovery \
  --query Name --output text

# Lambda: crear y borrar una función mínima con LabRole y el runtime del Flujo 2.
LAMBDA_RUNTIME="${LAMBDA_RUNTIME:-python3.14}"
PROBE_NAME="pinwatch-check-$(date +%s)"
PROBE_DIR="$(mktemp -d)"
cleanup_lambda() {
  aws lambda delete-function --function-name "$PROBE_NAME" >/dev/null 2>&1 || true
  rm -rf "$PROBE_DIR"
}
trap 'cleanup; cleanup_lambda' EXIT
printf 'def handler(event, context):\n    return "ok"\n' >"$PROBE_DIR/probe.py"
python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1], "w").write(sys.argv[2], "probe.py")' \
  "$PROBE_DIR/probe.zip" "$PROBE_DIR/probe.py"
check "Lambda: crear función con LabRole y $LAMBDA_RUNTIME" \
  aws lambda create-function --function-name "$PROBE_NAME" --runtime "$LAMBDA_RUNTIME" \
  --role "$(lab_role_arn)" --handler probe.handler --zip-file "fileb://$PROBE_DIR/probe.zip" \
  --query Runtime --output text
check "Lambda: borrar la función de prueba" \
  aws lambda delete-function --function-name "$PROBE_NAME"
check "CloudWatch Logs: listar log groups" \
  aws logs describe-log-groups --log-group-name-prefix /aws/lambda/pinwatch --query 'length(logGroups)' --output text

if ((FAILURES > 0)); then
  die "$FAILURES prueba(s) fallaron. Revisa los mensajes antes de correr up.sh."
fi
log "El lab permite todo lo que usan los scripts."
