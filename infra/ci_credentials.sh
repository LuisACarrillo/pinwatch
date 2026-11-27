#!/usr/bin/env bash
# Copia las credenciales del Learner Lab a los secretos del repo que usa el CI/CD.
# Las credenciales del lab vencen con la sesión (~4 h): se corre cada vez que se reinicia el lab,
# después de pegar las de AWS Details en ~/.aws/credentials.
#   bash infra/ci_credentials.sh            # perfil default
#   bash infra/ci_credentials.sh <perfil>
# Necesita GitHub CLI con sesión iniciada (gh auth login) y acceso de colaborador al repo.
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INFRA_DIR/lib.sh"

PROFILE="${1:-default}"
export AWS_PROFILE="$PROFILE"
require_cmd gh
gh auth status >/dev/null 2>&1 || die "GitHub CLI no tiene sesión. Ejecuta: gh auth login"

# Valida que las credenciales sirvan antes de subirlas.
aws_session

for pair in \
  "AWS_ACCESS_KEY_ID aws_access_key_id" \
  "AWS_SECRET_ACCESS_KEY aws_secret_access_key" \
  "AWS_SESSION_TOKEN aws_session_token"; do
  read -r secret_name key <<<"$pair"
  value="$(aws configure get "$key" --profile "$PROFILE" || true)"
  [[ -n "$value" ]] || die "El perfil $PROFILE no tiene $key en ~/.aws/credentials."
  # Por stdin, para que el valor no aparezca en la lista de procesos.
  printf '%s' "$value" | gh secret set "$secret_name" >/dev/null
  log "Secreto $secret_name actualizado"
done

log "Listo: el CI/CD desplegará en la cuenta $ACCOUNT_ID hasta que venza la sesión del lab."
