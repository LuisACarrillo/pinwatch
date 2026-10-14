#!/usr/bin/env bash
# Bastión EC2 de PinWatch: puerta de entrada a la base RDS privada (psql, migraciones).
#   infra/ec2.sh up       crea la instancia o arranca la existente
#   infra/ec2.sh status   muestra estado, IP y registro en Session Manager
#   infra/ec2.sh down     termina la instancia y borra su security group
#
# Se entra por Session Manager, sin puertos abiertos. Variables opcionales:
#   EC2_INSTANCE_TYPE  tipo de instancia (t3.micro por defecto)
#   EC2_ACCESS         ssm (por defecto) o ssh; con ssh se abre el 22 solo a SSH_CIDR
#   SSH_CIDR           origen permitido para SSH (por defecto, tu IP pública /32)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTANCE_NAME="pinwatch-bastion"
SG_NAME="pinwatch-bastion-sg"
INSTANCE_TYPE="${EC2_INSTANCE_TYPE:-t3.micro}"
ACCESS="${EC2_ACCESS:-ssm}"
KEY_NAME="vockey"
INSTANCE_PROFILE="LabInstanceProfile"
AMI_PARAMETER="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
# El agente de SSM ya viene en Amazon Linux 2023; solo falta el cliente de PostgreSQL.
USER_DATA='#!/bin/bash
dnf install -y postgresql16 || dnf install -y postgresql15
'

[[ "$ACCESS" == "ssm" || "$ACCESS" == "ssh" ]] || die "EC2_ACCESS debe ser ssm o ssh."

default_vpc() {
  local vpc
  vpc="$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' --output text)"
  [[ "$vpc" != "None" ]] || die "La cuenta no tiene VPC default."
  printf '%s\n' "$vpc"
}

# Imprime el id del security group o nada si no existe.
find_sg() {
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" "Name=tag:Project,Values=$PROJECT_TAG" \
    --query 'SecurityGroups[0].GroupId' --output text | grep -v '^None$' || true
}

# Imprime "id estado ip" de la instancia viva (no terminada) o nada.
find_instance() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[0].[InstanceId, State.Name, PublicIpAddress]' \
    --output text | head -n 1
}

ssh_rules() {
  aws ec2 describe-security-groups --group-ids "$1" \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].CidrIp' --output text
}

ensure_sg() {
  local vpc="$1" sg
  sg="$(find_sg)"
  if [[ -z "$sg" ]]; then
    sg="$(aws ec2 create-security-group --group-name "$SG_NAME" --vpc-id "$vpc" \
      --description "PinWatch bastion: sin entrada, acceso por Session Manager" \
      --tag-specifications "$(tag_spec security-group "$SG_NAME")" \
      --query GroupId --output text)"
    log "Security group creado: $sg"
  else
    log "Security group existente: $sg"
  fi

  local cidr=""
  if [[ "$ACCESS" == "ssh" ]]; then
    cidr="${SSH_CIDR:-$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32}"
  fi
  # Retira las reglas SSH que no correspondan: todas en modo ssm, las de IPs viejas en modo ssh.
  local old
  for old in $(ssh_rules "$sg"); do
    if [[ "$old" != "$cidr" ]]; then
      aws ec2 revoke-security-group-ingress --group-id "$sg" \
        --protocol tcp --port 22 --cidr "$old" >/dev/null
      log "Regla SSH retirada: $old"
    fi
  done
  if [[ -n "$cidr" ]] && ! ssh_rules "$sg" | tr '\t' '\n' | grep -qx "$cidr"; then
    aws ec2 authorize-security-group-ingress --group-id "$sg" \
      --protocol tcp --port 22 --cidr "$cidr" >/dev/null
    log "SSH permitido desde $cidr"
  fi
  [[ "$ACCESS" == "ssm" ]] && log "Sin reglas de entrada: el acceso es por Session Manager."
  SG_ID="$sg"
}

latest_ami() {
  aws ssm get-parameter --name "$AMI_PARAMETER" --query Parameter.Value --output text 2>/dev/null ||
    aws ec2 describe-images --owners amazon \
      --filters "Name=name,Values=al2023-ami-2023.*-kernel-*-x86_64" "Name=state,Values=available" \
      --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text
}

# Subred default de una zona que ofrezca el tipo de instancia (us-east-1e no tiene t3).
pick_subnet() {
  local vpc="$1" zones
  zones="$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
    --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' ',')"
  [[ -n "$zones" ]] || die "El tipo $INSTANCE_TYPE no está disponible en $AWS_REGION."
  aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$vpc" "Name=default-for-az,Values=true" \
    "Name=availability-zone,Values=$zones" \
    --query 'sort_by(Subnets, &AvailabilityZone)[0].SubnetId' --output text
}

ssm_ping() {
  aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$1" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "desconocido"
}

wait_ssm_online() {
  local id="$1" attempt
  log "Esperando a que $id se registre en Session Manager (hasta 5 min)"
  for attempt in $(seq 1 30); do
    if [[ "$(ssm_ping "$id")" == "Online" ]]; then
      log "Registrada en Session Manager (Online)."
      return
    fi
    sleep 10
  done
  die "La instancia no se registró en Session Manager. Revisa que use LabInstanceProfile, o usa EC2_ACCESS=ssh."
}

ec2_up() {
  local vpc instance id state ip
  vpc="$(default_vpc)"
  ensure_sg "$vpc"

  instance="$(find_instance)"
  if [[ -n "$instance" ]]; then
    read -r id state ip <<<"$instance"
    log "Instancia existente: $id ($state)"
    if [[ "$state" == "stopping" ]]; then
      aws ec2 wait instance-stopped --instance-ids "$id"
      state="stopped"
    fi
    if [[ "$state" == "stopped" ]]; then
      log "Arrancando $id"
      aws ec2 start-instances --instance-ids "$id" >/dev/null
    fi
  else
    local ami subnet
    ami="$(latest_ami)"
    subnet="$(pick_subnet "$vpc")"
    log "Creando $INSTANCE_NAME ($INSTANCE_TYPE, $ami) en $subnet"
    # vockey se asocia siempre para poder pasar a SSH sin recrear la instancia.
    id="$(aws ec2 run-instances \
      --image-id "$ami" \
      --instance-type "$INSTANCE_TYPE" \
      --key-name "$KEY_NAME" \
      --iam-instance-profile "Name=$INSTANCE_PROFILE" \
      --subnet-id "$subnet" \
      --security-group-ids "$SG_ID" \
      --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
      --user-data "$USER_DATA" \
      --tag-specifications "$(tag_spec instance "$INSTANCE_NAME")" "$(tag_spec volume "$INSTANCE_NAME")" \
      --query 'Instances[0].InstanceId' --output text)"
    log "Instancia creada: $id"
  fi

  log "Esperando a que $id esté en running"
  aws ec2 wait instance-running --instance-ids "$id"
  ip="$(aws ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  log "En marcha: $id, IP pública $ip"

  if [[ "$ACCESS" == "ssm" ]]; then
    wait_ssm_online "$id"
    log "Entrar:  aws ssm start-session --target $id"
    log "Túnel a RDS:  bash infra/db_tunnel.sh"
  else
    log "Entrar:  ssh -i ~/.ssh/labsuser.pem ec2-user@$ip"
  fi
}

ec2_status() {
  local instance id
  instance="$(find_instance)"
  if [[ -z "$instance" ]]; then
    log "$INSTANCE_NAME: no existe"
  else
    read -r id _ <<<"$instance"
    log "$INSTANCE_NAME: $instance"
    log "Session Manager: $(ssm_ping "$id")"
  fi
  local sg
  sg="$(find_sg)"
  if [[ -z "$sg" ]]; then
    log "$SG_NAME: no existe"
  else
    log "$SG_NAME: $sg, SSH abierto a: $(ssh_rules "$sg" | tr '\t' ' ' | grep . || echo nadie)"
  fi
}

ec2_down() {
  local ids sg
  ids="$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=tag:Owner,Values=$OWNER_TAG" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  sg="$(find_sg)"
  if [[ -z "$ids" && -z "$sg" ]]; then
    log "No hay instancias ni security group de PinWatch; nada que borrar."
    return
  fi
  confirm "¿Terminar ${ids:-ninguna instancia} y borrar ${sg:-ningún security group}?" || die "Cancelado."

  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086 # ids es una lista separada por espacios
    aws ec2 terminate-instances --instance-ids $ids >/dev/null
    log "Terminando $ids"
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --instance-ids $ids
    log "Instancias terminadas."
  fi

  if [[ -n "$sg" ]]; then
    # La interfaz de red de la instancia tarda unos segundos en liberarse.
    local attempt
    for attempt in $(seq 1 6); do
      if aws ec2 delete-security-group --group-id "$sg" 2>/dev/null; then
        log "Security group $sg borrado."
        return
      fi
      sleep 10
    done
    warn "No se pudo borrar $sg todavía (DependencyViolation). Vuelve a correr el teardown en un minuto."
  fi
}

parse_args "$@"
aws_session
"ec2_$ACTION"
