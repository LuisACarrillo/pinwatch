# PinWatch

PinWatch es una red social visual para comunidades creativas, diseñadores y usuarios que quieren descubrir, compartir y organizar imágenes en tableros temáticos. Cada publicación es un pin: título, descripción, categoría e imagen. Desde el muro se explora el contenido por categorías y se guarda en tableros personales.

Hoy ese tipo de uso choca con plataformas autohospedadas lentas. Subir archivos pesados y, al mismo tiempo, consultar un feed de imágenes satura el servidor y degrada la experiencia. PinWatch se diseña en la nube para separar esas cargas: la interfaz habla con una API que escala bajo demanda, el archivo viaja directo al almacenamiento de objetos y el trabajo pesado —comprimir la imagen y generar la miniatura del feed— ocurre en segundo plano, sin bloquear la respuesta al usuario.

El resultado esperado es un muro fluido, tableros que se actualizan al guardar un pin y un repositorio de imágenes disponible aunque el volumen de contenido y de consultas crezca.

## Estructura del monorepo

El repositorio separa la API, la interfaz y los pipelines. El frontend se gestiona con pnpm; el backend es una aplicación Python independiente.

```text
pinwatch/
├── backend/                  # API FastAPI, empaquetable en AWS Lambda
│   ├── main.py               # App, GET /health, POST /pins/presign-url y handler de Mangum
│   ├── app_secrets.py        # Configuración leída de AWS Secrets Manager
│   └── requirements.txt
├── frontend/                 # Aplicación React con Vite
│   └── src/
│       ├── components/       # Componentes de interfaz
│       └── services/         # Cliente de la API
├── infra/                    # Infraestructura como código y automatización
│   ├── setup_originals_bucket.py # Bucket S3 de originales y CORS
│   ├── secrets.sh            # Secreto en Secrets Manager (JWT y BD)
│   ├── sns.sh                # Tópico Amazon SNS (pinwatch-events)
│   ├── ec2.sh                # Bastión EC2 y Session Manager
│   ├── rds.sh                # Amazon RDS PostgreSQL y migración de esquema
│   ├── schema.sql            # Esquema relacional (users, pins, boards, board_pins, notifications)
│   ├── up.sh                 # Orquestador de infraestructura
│   ├── verify.sh             # Comprobaciones end-to-end
│   └── teardown.sh           # Limpieza de recursos

├── Makefile                  # Comandos rápidos: make up, make down, make status
├── start_backend.sh          # Script orquestador del backend e infra
├── .github/workflows/        # Pipelines de integración continua
├── package.json              # Scripts del workspace pnpm
└── pnpm-workspace.yaml
```

| Ruta | Responsabilidad |
| --- | --- |
| `backend/` | API HTTP con FastAPI. `POST /pins/presign-url` firma la subida a S3. `handler` en `main.py` adapta la app a AWS Lambda mediante Mangum. |
| `frontend/` | Interfaz React. El formulario de un pin pide la URL firmada y sube la imagen directo al bucket. |
| `infra/` | Scripts de infraestructura (S3, Secrets Manager, Bastión EC2, RDS PostgreSQL y esquema SQL). |
| `Makefile` / `start_backend.sh` | Levanta toda la infraestructura en orden y arranca la API del backend. |
| `.github/workflows/` | Definiciones de CI. El directorio queda reservado para los pipelines del equipo. |

## Requisitos

- Python 3.10 o superior (`python3-venv`, `python3-pip`)
- Node.js 22 o superior
- pnpm 12 (`corepack enable` y `corepack prepare pnpm@12.11.2 --activate`)
- AWS CLI v2 (`aws configure` configurado en `us-east-1` en el mismo entorno donde corre la API)
- `make` (opcional, para usar `make up`)

En **Ubuntu / WSL**, instala las dependencias del sistema necesarias:

```bash
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip make curl openssl
```

> **Nota en WSL:** Si el repositorio está en el disco de Windows, la ruta en la terminal de Ubuntu empieza por `/mnt/c/`. Los scripts de bash y la API deben ejecutarse dentro de Ubuntu con las credenciales de AWS configuradas en esa sesión.


## Backend

La API firma la subida con las credenciales de AWS del proceso que la ejecuta y se conecta a la infraestructura en la nube (S3, Secrets Manager, RDS).

### Levantar todo el Backend con un solo comando

Con las credenciales de AWS configuradas en tu terminal, levanta la infraestructura completa (S3, Secrets, EC2 bastión, RDS PostgreSQL, esquema relacional) y arranca la API con:

```bash
make up
```

O directamente ejecutando el script orquestador:

```bash
bash start_backend.sh
```

Este script ejecuta automáticamente en el orden estricto necesario:
1. Valida la sesión activa de AWS en `us-east-1`.
2. `python3 infra/setup_originals_bucket.py`: crea o verifica el bucket S3 `pinwatch-originals-<cuenta>` y aplica su política CORS.
3. `bash infra/secrets.sh up`: genera y configura el secreto `pinwatch/app` en AWS Secrets Manager con llaves JWT aleatorias.
4. `bash infra/sns.sh up`: crea o verifica el tópico Amazon SNS `pinwatch-events` y registra `sns_topic_arn` en Secrets Manager.
5. `bash infra/ec2.sh up`: levanta el bastión EC2 `pinwatch-bastion` (`t3.micro`) con SSM y cliente `psql`.
6. `bash infra/rds.sh up`: aprovisiona la instancia Amazon RDS PostgreSQL (`pinwatch-db`), DB Subnet Group y Security Group (`pinwatch-db-sg`), actualiza `pinwatch/app` con `db_host`, `db_port`, `db_name`, `db_username`, `db_password`, y aplica `infra/schema.sql` a través del bastión.
7. Prepara el entorno virtual de Python (`.venv` o `~/pinwatch-venv`), instala las dependencias de `backend/requirements.txt` y levanta el servidor Uvicorn en modo reload.


La API quedará disponible de inmediato:
- Salud local: [http://localhost:8000/health](http://localhost:8000/health)
- Documentación interactiva: [http://localhost:8000/docs](http://localhost:8000/docs)
- Subida: `POST /pins/presign-url` devuelve una URL firmada de `PutObject` hacia `originals/`
- Handler de Lambda: `main.handler`


## Frontend

En otra terminal, desde la raíz del repositorio y en Windows:

```powershell
pnpm install
pnpm dev
```

La aplicación queda en [http://localhost:5173](http://localhost:5173). La URL de la API se configura con `VITE_API_URL` (ver `frontend/.env.example`). Si no existe, el cliente usa `http://localhost:8000`.

Con la API y la interfaz en marcha, **Nuevo pin** pide la URL firmada y sube la imagen directo a S3.

Otros scripts del workspace:

```powershell
pnpm build
pnpm lint
pnpm preview
```

## Infraestructura en AWS: S3, Secrets Manager, Bastión EC2 y Amazon RDS

Todo se crea con la AWS CLI y scripts de bash en `infra/`. Cada script es idempotente y se puede correr varias veces: si el recurso ya existe, lo reutiliza. `teardown.sh` borra lo creado por los scripts (con confirmación).

| Servicio | Recurso | Para qué |
| --- | --- | --- |
| S3 | `pinwatch-originals-<cuenta>` | Almacenamiento de las imágenes originales subidas directamente desde el navegador vía URLs prefirmadas. |
| Secrets Manager | Secreto `pinwatch/app` | JSON con la configuración sensible: `jwt_signing_key`, `jwt_algorithm`, `db_host`, `db_port`, `db_name`, `db_username` y `db_password`. Nada de esto vive en el repo. |
| EC2 | Instancia `pinwatch-bastion` (`t3.micro`, Amazon Linux 2023, `LabInstanceProfile`, cliente `psql` 16) | Bastión para entrar a la RDS privada: consola, `psql` y túnel para migraciones. El flujo de la aplicación no depende de que esté prendida. |
| EC2 | Security group `pinwatch-bastion-sg` | Sin reglas de entrada. Se entra por Session Manager, no por SSH. |
| RDS | Instancia `pinwatch-db` (`db.t3.micro`, PostgreSQL 16) | Base de datos relacional para usuarios, pines, tableros y asociaciones. |
| EC2 / RDS | Security group `pinwatch-db-sg` | Acepta conexiones en el puerto 5432 únicamente desde `pinwatch-bastion-sg`. |
| RDS | DB Subnet Group `pinwatch-db-subnet-group` | Agrupa subredes de la VPC en múltiples zonas de disponibilidad para alta compatibilidad en RDS. |

Costo: la instancia cobra solo mientras está prendida (~USD 0.015/h con su IP pública); el disco de 8 GB y el secreto cobran aunque esté apagada (~USD 0.64 y 0.40 al mes). Con `teardown.sh` el costo queda en cero.

### Requisitos previos

- Learner Lab iniciado (indicador en verde).
- Las credenciales de **AWS Details** copiadas en `~/.aws/credentials`: `aws_access_key_id`, `aws_secret_access_key` y `aws_session_token`.
- Región `us-east-1` (`aws configure set region us-east-1`). Los scripts se niegan a correr en otra.
- En Ubuntu / macOS: AWS CLI v2, `python3`, `openssl`, `curl` y [session-manager-plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-debian-and-ubuntu.html):

```bash
curl -fsSLo /tmp/smp.deb https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb
sudo dpkg -i /tmp/smp.deb
```

### Comandos de gestión de infraestructura

```bash
make up                 # Levanta toda la infraestructura en orden y arranca la API
make status             # Muestra qué existe en Secrets Manager, EC2 bastión y RDS
make verify             # Comprueba que la infraestructura funciona de punta a punta
make down               # Borra los recursos creados (pide confirmación)
```

Cada script también se puede ejecutar y gestionar de forma individual:
- `bash infra/secrets.sh up|status|down`
- `bash infra/ec2.sh up|status|down`
- `bash infra/rds.sh up|status|down` (`down` acepta `--yes`)
- `bash infra/teardown.sh [--yes | --status]`


### Entrar al bastión y a la base

```bash
aws ssm start-session --target <id de la instancia>   # consola en el bastión (lo imprime up.sh)
bash infra/db_tunnel.sh                                # túnel localhost:15432 -> RDS
psql -h localhost -p 15432 -U <usuario> <base>         # en otra terminal, mientras el túnel está abierto
```

`db_tunnel.sh` toma `db_host` y `db_port` de `pinwatch/app`; también acepta `bash infra/db_tunnel.sh <host> [puerto] [puerto-local]`. Para que funcione, el security group de la RDS tiene que aceptar el 5432 desde `pinwatch-bastion-sg`.

### Secretos desde la API

`backend/app_secrets.py` lee `pinwatch/app` con boto3 y lo guarda en memoria 5 minutos, así una Lambda caliente no consulta Secrets Manager en cada request:

```python
from app_secrets import jwt_settings, database_settings

signing_key, algorithm = jwt_settings()
db = database_settings()  # host, port, name, username, password
```

Si la RDS se crea con `--manage-master-user-password`, RDS guarda usuario y contraseña en su propio secreto (`rds!db-…`) y lo rota cada 7 días. En ese caso `pinwatch/app` lleva `db_secret_arn` con el ARN de ese secreto, en lugar de `db_username` y `db_password`, y el helper lo sigue. Así nunca queda una copia vieja de la contraseña. Si la base rechaza la contraseña tras una rotación, `app_secrets.clear_cache()` fuerza a releerla.

Pruebas del helper (no llaman a AWS):

```bash
~/pinwatch-venv/bin/pip install -r backend/requirements-dev.txt
~/pinwatch-venv/bin/python -m pytest backend
```

### Variables de entorno

Los scripts leen la cuenta y la región de la sesión de la AWS CLI; las variables son opcionales.

| Variable | Por defecto | Uso |
| --- | --- | --- |
| `APP_SECRET_NAME` | `pinwatch/app` | Nombre del secreto, para los scripts y la API. |
| `APP_SECRET_TTL_SECONDS` | `300` | Segundos que la API guarda el secreto en memoria. |
| `JWT_SIGNING_KEY`, `JWT_ALGORITHM`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USERNAME`, `DB_PASSWORD`, `DB_SECRET_ARN` | vacías | Respaldo local: si se definen, ganan sobre el secreto y la API no llama a AWS. Ver `backend/.env.example`. |
| `EC2_INSTANCE_TYPE` | `t3.micro` | Tipo de la instancia del bastión. |
| `EC2_ACCESS` | `ssm` | `ssh` abre el puerto 22 a `SSH_CIDR` como respaldo si Session Manager falla. |
| `SSH_CIDR` | Tu IP pública `/32` | Origen permitido para SSH con `EC2_ACCESS=ssh`. |

### Verificar que funciona

`bash infra/verify.sh` debe terminar así:

```text
[verify] OK     Secreto pinwatch/app legible; llaves: jwt_algorithm,jwt_signing_key
[verify] OK     Bastión en running: i-0123456789abcdef0
[verify] OK     Registrado en Session Manager
[verify] OK     start-session funciona; en el bastión: psql (PostgreSQL) 16.x
[verify] OK     Security group sin reglas de entrada
[verify] Todo funciona.
```

### Problemas comunes del Learner Lab

- **`Las credenciales no son válidas o vencieron` / `ExpiredToken`**: la sesión del lab dura unas 4 horas. Reinicia el lab y vuelve a copiar las tres líneas de **AWS Details** a `~/.aws/credentials`.
- **El bastión aparece en `stopped`**: el lab lo apaga al terminar la sesión. `bash infra/up.sh` lo vuelve a arrancar y espera a que Session Manager lo vea.
- **`Cannot perform start session: EOF`**: `aws ssm start-session` necesita una terminal interactiva. Córrelo directo en la terminal de Ubuntu, no dentro de otro comando.
- **El nombre `pinwatch/app` está ocupado justo después de un teardown**: Secrets Manager tarda unos segundos en liberar el nombre; `secrets.sh` reintenta solo.
- **`DependencyViolation` al borrar el security group**: la interfaz de red de la instancia tardó en liberarse. Repite `bash infra/teardown.sh --yes` en un minuto.
- **Session Manager no registra la instancia**: como respaldo, `EC2_ACCESS=ssh bash infra/ec2.sh up` abre el 22 solo a tu IP; entra con `ssh -i ~/.ssh/labsuser.pem ec2-user@<IP>` (`labsuser.pem` se descarga en **AWS Details**).
- **`AccessDenied`**: la acción está restringida en Learner Lab. No uses otra cuenta ni otro rol; avisa al equipo.
