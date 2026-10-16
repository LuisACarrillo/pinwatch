#!/usr/bin/env bash
# Script orquestador para levantar toda la infraestructura y el backend de PinWatch.
# Ejecuta los scripts en el orden correcto y arranca la API con Uvicorn.
#   bash start_backend.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
BACKEND_DIR="$ROOT_DIR/backend"

source "$INFRA_DIR/lib.sh"

log "Iniciando despliegue y arranque del Backend de PinWatch..."

# 1. Validar sesión y credenciales de AWS
aws_session

# 2. Bucket S3 de imágenes originales y configuración CORS
log "1/5 Bucket S3 de imágenes originales"
python3 "$INFRA_DIR/setup_originals_bucket.py"

# 3. AWS Secrets Manager (JWT keys y configuración base)
log "2/5 Secrets Manager (pinwatch/app)"
bash "$INFRA_DIR/secrets.sh" up

# 4. Bastión EC2 (acceso seguro vía Session Manager y cliente psql)
log "3/5 Bastión EC2 (pinwatch-bastion)"
bash "$INFRA_DIR/ec2.sh" up

# 5. Base de datos Amazon RDS PostgreSQL y migración de esquema
log "4/5 Amazon RDS PostgreSQL y esquema de base de datos"
bash "$INFRA_DIR/rds.sh" up

# 6. Preparación del entorno Python del backend
log "5/5 Preparando entorno de ejecución Python y dependencias"
VENV_PATH=""
if [[ -d "$ROOT_DIR/.venv" ]]; then
  VENV_PATH="$ROOT_DIR/.venv"
elif [[ -d "$HOME/pinwatch-venv" ]]; then
  VENV_PATH="$HOME/pinwatch-venv"
else
  log "Creando entorno virtual en $ROOT_DIR/.venv..."
  python3 -m venv "$ROOT_DIR/.venv"
  VENV_PATH="$ROOT_DIR/.venv"
fi

# Instalar dependencias requeridas
"$VENV_PATH/bin/pip" install --quiet --upgrade pip
"$VENV_PATH/bin/pip" install --quiet -r "$BACKEND_DIR/requirements.txt"

log "Infraestructura lista y dependencias instaladas."
log "Iniciando API FastAPI en http://127.0.0.1:8000 ..."
log "Documentación interactiva disponible en http://127.0.0.1:8000/docs"

exec "$VENV_PATH/bin/uvicorn" main:app --app-dir "$BACKEND_DIR" --host 127.0.0.1 --port 8000 --reload
