#!/usr/bin/env bash
# Instancia EC2 de servicios auxiliares de PinWatch (runner de GitHub Actions).
#   infra/ec2.sh up       crea la instancia o arranca la existente
#   infra/ec2.sh status   muestra estado e IP
#   infra/ec2.sh down     termina la instancia y borra su security group
#
# Variables opcionales:
#   EC2_INSTANCE_TYPE  tipo de instancia (t3.micro por defecto)
#   SSH_CIDR           origen permitido para SSH (por defecto, tu IP pública /32)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTANCE_NAME="pinwatch-aux"
SG_NAME="pinwatch-aux-sg"
INSTANCE_TYPE="${EC2_INSTANCE_TYPE:-t3.micro}"
KEY_NAME="vockey"
INSTANCE_PROFILE="LabInstanceProfile"
AMI_PARAMETER="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"

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

ensure_sg() {
  local vpc="$1" sg cidr
  sg="$(find_sg)"
  if [[ -z "$sg" ]]; then
    sg="$(aws ec2 create-security-group --group-name "$SG_NAME" --vpc-id "$vpc" \
      --description "PinWatch servicios auxiliares: SSH desde la IP del equipo" \
      --tag-specifications "$(tag_spec security-group "$SG_NAME")" \
      --query GroupId --output text)"
    log "Security group creado: $sg"
  else
    log "Security group existente: $sg"
  fi

  cidr="${SSH_CIDR:-$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32}"
  # Quita reglas SSH de IPs anteriores para no acumular orígenes abiertos.
  local old
  for old in $(aws ec2 describe-security-groups --group-ids "$sg" \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].CidrIp' --output text); do
    if [[ "$old" != "$cidr" ]]; then
      aws ec2 revoke-security-group-ingress --group-id "$sg" \
        --protocol tcp --port 22 --cidr "$old" >/dev/null
      log "Regla SSH anterior retirada: $old"
    fi
  done
  if ! aws ec2 describe-security-groups --group-ids "$sg" \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].CidrIp' \
    --output text | grep -qx "$cidr"; then
    aws ec2 authorize-security-group-ingress --group-id "$sg" \
      --protocol tcp --port 22 --cidr "$cidr" >/dev/null
    log "SSH permitido desde $cidr"
  fi
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
    id="$(aws ec2 run-instances \
      --image-id "$ami" \
      --instance-type "$INSTANCE_TYPE" \
      --key-name "$KEY_NAME" \
      --iam-instance-profile "Name=$INSTANCE_PROFILE" \
      --subnet-id "$subnet" \
      --security-group-ids "$SG_ID" \
      --associate-public-ip-address \
      --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
      --user-data "$(printf '#!/bin/bash\ndnf install -y git jq\n')" \
      --tag-specifications "$(tag_spec instance "$INSTANCE_NAME")" "$(tag_spec volume "$INSTANCE_NAME")" \
      --query 'Instances[0].InstanceId' --output text)"
    log "Instancia creada: $id"
  fi

  log "Esperando a que $id esté en running"
  aws ec2 wait instance-running --instance-ids "$id"
  ip="$(aws ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  log "Lista: $id, IP pública $ip"
  log "SSH: ssh -i ~/.ssh/labsuser.pem ec2-user@$ip"
}

ec2_status() {
  local instance
  instance="$(find_instance)"
  if [[ -z "$instance" ]]; then
    log "$INSTANCE_NAME: no existe"
  else
    log "$INSTANCE_NAME: $instance"
  fi
  log "$SG_NAME: $(find_sg)"
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
    for attempt in 1 2 3 4 5 6; do
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
