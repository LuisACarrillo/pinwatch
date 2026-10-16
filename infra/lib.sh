# Funciones comunes de los scripts de infra/. Se carga con:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# No se ejecuta por sí solo.

PROJECT_TAG="pinwatch"
OWNER_TAG="luis-fernando"
REQUIRED_REGION="us-east-1"

log() { printf '[%s] %s\n' "$(basename "$0" .sh)" "$*"; }
warn() { printf '[%s] AVISO: %s\n' "$(basename "$0" .sh)" "$*" >&2; }
die() {
  printf '[%s] ERROR: %s\n' "$(basename "$0" .sh)" "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta el comando '$1'. Instálalo antes de continuar."
}

# Lee ACTION (up | down | status) y --yes de los argumentos del script.
parse_args() {
  ACTION=""
  ASSUME_YES="${ASSUME_YES:-0}"
  for arg in "$@"; do
    case "$arg" in
      up | down | status) ACTION="$arg" ;;
      -y | --yes) ASSUME_YES=1 ;;
      *) die "Argumento desconocido: $arg. Uso: $(basename "$0") up|down|status [--yes]" ;;
    esac
  done
  [[ -n "$ACTION" ]] || die "Uso: $(basename "$0") up|down|status [--yes]"
}

# Pide confirmación salvo que se haya pasado --yes.
confirm() {
  [[ "$ASSUME_YES" == 1 ]] && return 0
  [[ -t 0 ]] || die "No hay terminal interactiva para confirmar. Repite con --yes."
  local answer
  read -r -p "$1 [s/N] " answer
  [[ "$answer" =~ ^[sSyY]$ ]]
}

# Verifica credenciales y región, y deja ACCOUNT_ID y AWS_REGION exportadas.
aws_session() {
  require_cmd aws
  AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
  [[ -n "$AWS_REGION" ]] || die "No hay región. Ejecuta 'aws configure set region $REQUIRED_REGION'."
  [[ "$AWS_REGION" == "$REQUIRED_REGION" ]] ||
    die "La sesión usa la región $AWS_REGION; PinWatch solo se despliega en $REQUIRED_REGION."
  export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" ||
    die "Las credenciales no son válidas o vencieron. Inicia el lab y copia las de 'AWS Details' a ~/.aws/credentials."
  export ACCOUNT_ID
  log "Cuenta $ACCOUNT_ID, región $AWS_REGION"
}

# ARN de LabRole en la cuenta actual (el único rol que se puede usar en Learner Lab).
lab_role_arn() {
  aws iam get-role --role-name LabRole --query Role.Arn --output text 2>/dev/null ||
    printf 'arn:aws:iam::%s:role/LabRole\n' "$ACCOUNT_ID"
}

# Corre un comando en una instancia por Session Manager e imprime su salida.
# AWS-StartNonInteractiveCommand no usa un shell: recibe un solo comando con sus argumentos.
# El plugin necesita stdin abierto mientras corre; `sleep` lo mantiene esos segundos.
ssm_run() {
  local id="$1" command="$2" hold="${3:-15}"
  local params
  params="$(python3 -c 'import json, sys; print(json.dumps({"command": [sys.argv[1]]}))' "$command")"
  if command -v timeout >/dev/null 2>&1; then
    sleep "$hold" | timeout 60 aws ssm start-session --target "$id" \
      --document-name AWS-StartNonInteractiveCommand \
      --parameters "$params" 2>&1 | tr -d '\r' || true
  elif command -v gtimeout >/dev/null 2>&1; then
    sleep "$hold" | gtimeout 60 aws ssm start-session --target "$id" \
      --document-name AWS-StartNonInteractiveCommand \
      --parameters "$params" 2>&1 | tr -d '\r' || true
  else
    sleep "$hold" | aws ssm start-session --target "$id" \
      --document-name AWS-StartNonInteractiveCommand \
      --parameters "$params" 2>&1 | tr -d '\r' || true
  fi
}



# Etiquetas que identifican los recursos de esta parte; teardown.sh solo borra lo que las tenga.
tag_spec() {
  printf 'ResourceType=%s,Tags=[{Key=Project,Value=%s},{Key=Owner,Value=%s},{Key=Name,Value=%s}]' \
    "$1" "$PROJECT_TAG" "$OWNER_TAG" "$2"
}
