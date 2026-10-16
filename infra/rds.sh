#!/usr/bin/env bash
# Base de datos Amazon RDS PostgreSQL para PinWatch.
#   infra/rds.sh up       crea la instancia RDS, subnet group, security group,
#                         actualiza el secreto pinwatch/app y aplica el esquema relacional
#   infra/rds.sh status   muestra el estado, endpoint y puerto de la RDS
#   infra/rds.sh down     elimina la RDS, subnet group y security group
#
# Configuración sensible y conexión se registran automáticamente en Secrets Manager.
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INFRA_DIR/lib.sh"

DB_INSTANCE_IDENTIFIER="${RDS_INSTANCE_IDENTIFIER:-pinwatch-db}"
DB_NAME="${RDS_DB_NAME:-pinwatch}"
DB_USERNAME="${RDS_DB_USERNAME:-postgres}"
DB_INSTANCE_CLASS="${RDS_INSTANCE_CLASS:-db.t3.micro}"
DB_SG_NAME="pinwatch-db-sg"
DB_SUBNET_GROUP_NAME="pinwatch-db-subnet-group"
APP_SECRET_NAME="${APP_SECRET_NAME:-pinwatch/app}"
SCHEMA_FILE="$INFRA_DIR/schema.sql"

default_vpc() {
  local vpc
  vpc="$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' --output text)"
  [[ "$vpc" != "None" && -n "$vpc" ]] || die "La cuenta no tiene VPC por defecto."
  printf '%s\n' "$vpc"
}

find_bastion_sg() {
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=pinwatch-bastion-sg" "Name=tag:Project,Values=$PROJECT_TAG" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true
}

find_db_sg() {
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$DB_SG_NAME" "Name=tag:Project,Values=$PROJECT_TAG" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true
}

ensure_db_sg() {
  local vpc="$1" sg bastion_sg
  sg="$(find_db_sg)"
  if [[ -z "$sg" ]]; then
    sg="$(aws ec2 create-security-group --group-name "$DB_SG_NAME" --vpc-id "$vpc" \
      --description "PinWatch RDS: trafico PostgreSQL desde bastion y servicios autorizados" \
      --tag-specifications "$(tag_spec security-group "$DB_SG_NAME")" \
      --query GroupId --output text)"
    log "Security group de RDS creado: $sg"
  else
    log "Security group de RDS existente: $sg"
  fi

  bastion_sg="$(find_bastion_sg)"
  if [[ -n "$bastion_sg" ]]; then
    local has_rule
    has_rule="$(aws ec2 describe-security-groups --group-ids "$sg" \
      --query "SecurityGroups[0].IpPermissions[?FromPort==\`5432\` && UserIdGroupPairs[?GroupId=='$bastion_sg']].FromPort" \
      --output text 2>/dev/null || true)"
    if [[ -z "$has_rule" ]]; then
      aws ec2 authorize-security-group-ingress --group-id "$sg" \
        --protocol tcp --port 5432 --source-group "$bastion_sg" >/dev/null
      log "Trafico en puerto 5432 permitido desde $bastion_sg"
    fi
  else
    warn "No se encontro pinwatch-bastion-sg aun. Recuerda crearlo con: bash infra/ec2.sh up"
  fi

  DB_SG_ID="$sg"
}

ensure_subnet_group() {
  local vpc="$1" exists
  exists="$(aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
    --query 'DBSubnetGroups[0].DBSubnetGroupName' --output text 2>/dev/null || true)"

  if [[ "$exists" == "$DB_SUBNET_GROUP_NAME" ]]; then
    log "DB Subnet Group existente: $DB_SUBNET_GROUP_NAME"
    return
  fi

  # RDS requiere subredes en al menos 2 zonas de disponibilidad distintas
  local subnets
  subnets="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" \
    --query 'Subnets[].[SubnetId, AvailabilityZone]' --output text |
    python3 -c '
import sys
zones = {}
for line in sys.stdin:
    parts = line.strip().split()
    if len(parts) == 2 and parts[1] not in zones:
        zones[parts[1]] = parts[0]
if len(zones) < 2:
    sys.exit(1)
print(" ".join(zones.values()))
')" || die "No hay suficientes zonas de disponibilidad en la VPC para el Subnet Group de RDS."

  # shellcheck disable=SC2086
  aws rds create-db-subnet-group \
    --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
    --db-subnet-group-description "Subnet group para RDS PostgreSQL PinWatch" \
    --subnet-ids $subnets \
    --tags "Key=Project,Value=$PROJECT_TAG" "Key=Owner,Value=$OWNER_TAG" >/dev/null
  log "DB Subnet Group creado: $DB_SUBNET_GROUP_NAME"
}

get_db_password() {
  local current_pass=""
  current_pass="$(aws secretsmanager get-secret-value --secret-id "$APP_SECRET_NAME" \
    --query SecretString --output text 2>/dev/null |
    python3 -c 'import json, sys; print(json.load(sys.stdin).get("db_password", ""))' 2>/dev/null || true)"

  if [[ -n "$current_pass" ]]; then
    printf '%s' "$current_pass"
  else
    require_cmd openssl
    openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20
  fi
}

update_app_secret() {
  local host="$1" port="$2" name="$3" username="$4" password="$5"
  require_cmd python3

  local current desired
  current="$(mktemp)"
  desired="$(mktemp)"
  trap 'rm -f "${current:-}" "${desired:-}"' EXIT

  if aws secretsmanager get-secret-value --secret-id "$APP_SECRET_NAME" \
    --query SecretString --output text >"$current" 2>/dev/null; then
    DB_HOST="$host" DB_PORT="$port" DB_NAME="$name" DB_USER="$username" DB_PASS="$password" \
      python3 -c '
import json, os, sys
secret = json.load(sys.stdin)
secret["db_host"] = os.environ["DB_HOST"]
secret["db_port"] = os.environ["DB_PORT"]
secret["db_name"] = os.environ["DB_NAME"]
secret["db_username"] = os.environ["DB_USER"]
secret["db_password"] = os.environ["DB_PASS"]
json.dump(secret, open(sys.argv[1], "w"))
' "$desired" <"$current"

    aws secretsmanager put-secret-value --secret-id "$APP_SECRET_NAME" \
      --secret-string "file://$desired" >/dev/null
    log "Secreto $APP_SECRET_NAME actualizado con datos de conexion a RDS (db_host, db_port, db_name, db_username)"
  else
    warn "No existe el secreto $APP_SECRET_NAME. Ejecuta 'bash infra/secrets.sh up' primero para crearlo."
  fi
}

apply_schema_via_bastion() {
  local host="$1" port="$2" name="$3" username="$4" password="$5"
  local instance_id
  instance_id="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=pinwatch-bastion" "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"

  if [[ "$instance_id" == "None" || -z "$instance_id" ]]; then
    warn "El bastión pinwatch-bastion no está encendido. No se aplicó schema.sql automáticamente."
    warn "Para aplicar el esquema después, inicia el bastión y ejecuta: bash infra/rds.sh up"
    return 0
  fi

  [[ -f "$SCHEMA_FILE" ]] || die "No se encontró $SCHEMA_FILE"

  log "Aplicando esquema relacional en RDS a través del bastión ($instance_id)..."
  local b64_sql
  b64_sql="$(base64 < "$SCHEMA_FILE" | tr -d '\r\n')"

  local inner_cmd="echo '$b64_sql' | base64 -d > /tmp/schema.sql && PGPASSWORD='$password' psql -h '$host' -p '$port' -U '$username' -d '$name' -f /tmp/schema.sql"
  local remote_cmd="bash -c \"$inner_cmd\""

  local out
  out="$(ssm_run "$instance_id" "$remote_cmd" 20)"
  if grep -E "(CREATE TABLE|CREATE INDEX|already exists)" <<<"$out" >/dev/null; then
    log "Esquema relacional aplicado con éxito en la base de datos '$name'."
  else
    warn "Salida de la migración: $out"
  fi

}

describe_rds() {
  aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --query 'DBInstances[0].[DBInstanceStatus, Endpoint.Address, Endpoint.Port]' --output text 2>/dev/null || true
}

rds_up() {
  require_cmd python3
  local vpc
  vpc="$(default_vpc)"

  log "Configurando red y seguridad para RDS..."
  ensure_db_sg "$vpc"
  ensure_subnet_group "$vpc"

  local rds_info status endpoint port
  rds_info="$(describe_rds)"

  local db_pass
  db_pass="$(get_db_password)"

  if [[ -z "$rds_info" ]]; then
    log "Creando instancia RDS PostgreSQL '$DB_INSTANCE_IDENTIFIER' ($DB_INSTANCE_CLASS)..."
    aws rds create-db-instance \
      --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
      --db-name "$DB_NAME" \
      --engine postgres \
      --db-instance-class "$DB_INSTANCE_CLASS" \
      --allocated-storage 20 \
      --storage-type gp3 \
      --master-username "$DB_USERNAME" \
      --master-user-password "$db_pass" \
      --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
      --vpc-security-group-ids "$DB_SG_ID" \
      --no-multi-az \
      --no-publicly-accessible \
      --backup-retention-period 0 \
      --tags "Key=Project,Value=$PROJECT_TAG" "Key=Owner,Value=$OWNER_TAG" "Key=Name,Value=$DB_INSTANCE_IDENTIFIER" >/dev/null

    log "Instancia RDS solicitada. Esperando a que esté disponible (esto toma unos minutos)..."
    aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"
    log "Instancia RDS lista y disponible."
  else
    read -r status endpoint port <<<"$rds_info"
    if [[ "$status" == "stopped" ]]; then
      log "La instancia RDS está detenida. Iniciando..."
      aws rds start-db-instance --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" >/dev/null
      aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"
    elif [[ "$status" != "available" ]]; then
      log "La instancia RDS está en estado '$status'. Esperando disponibilidad..."
      aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"
    else
      log "Instancia RDS existente y disponible."
    fi
  fi

  rds_info="$(describe_rds)"
  read -r status endpoint port <<<"$rds_info"
  log "Host RDS: $endpoint"
  log "Puerto RDS: $port"

  update_app_secret "$endpoint" "$port" "$DB_NAME" "$DB_USERNAME" "$db_pass"

  apply_schema_via_bastion "$endpoint" "$port" "$DB_NAME" "$DB_USERNAME" "$db_pass"

  log "RDS y esquema relacional listos para usar."
}

rds_status() {
  local rds_info status endpoint port
  rds_info="$(describe_rds)"
  if [[ -z "$rds_info" ]]; then
    log "RDS $DB_INSTANCE_IDENTIFIER: no existe"
    return
  fi
  read -r status endpoint port <<<"$rds_info"
  log "RDS $DB_INSTANCE_IDENTIFIER: estado '$status'"
  log "Endpoint: ${endpoint:-pendiente}"
  log "Puerto: ${port:-5432}"

  local in_secret
  in_secret="$(aws secretsmanager get-secret-value --secret-id "$APP_SECRET_NAME" \
    --query SecretString --output text 2>/dev/null |
    python3 -c 'import json, sys; s = json.load(sys.stdin); print("db_host:", s.get("db_host", "no registrado"))' 2>/dev/null || true)"
  log "Secrets Manager: $in_secret"
}

rds_down() {
  local rds_info
  rds_info="$(describe_rds)"
  if [[ -n "$rds_info" ]]; then
    confirm "¿Borrar la instancia RDS $DB_INSTANCE_IDENTIFIER y sus datos sin snapshot final?" || die "Cancelado."
    log "Eliminando instancia RDS $DB_INSTANCE_IDENTIFIER..."
    aws rds delete-db-instance --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
      --skip-final-snapshot >/dev/null
    log "Esperando eliminación de la instancia..."
    aws rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"
    log "Instancia RDS eliminada."
  else
    log "Instancia RDS $DB_INSTANCE_IDENTIFIER no existe."
  fi

  local exists_subnet
  exists_subnet="$(aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
    --query 'DBSubnetGroups[0].DBSubnetGroupName' --output text 2>/dev/null || true)"
  if [[ "$exists_subnet" == "$DB_SUBNET_GROUP_NAME" ]]; then
    aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" >/dev/null 2>&1 || true
    log "DB Subnet Group $DB_SUBNET_GROUP_NAME eliminado."
  fi

  local sg
  sg="$(find_db_sg)"
  if [[ -n "$sg" ]]; then
    aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 || true
    log "Security group $DB_SG_NAME eliminado."
  fi
}

parse_args "$@"
aws_session
"rds_$ACTION"
