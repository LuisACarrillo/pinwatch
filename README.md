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
│   └── requirements.txt
├── frontend/                 # Aplicación React con Vite
│   └── src/
│       ├── components/       # Componentes de interfaz
│       └── services/         # Cliente de la API
├── infra/                    # Bucket de originales y su CORS
├── .github/workflows/        # Pipelines de integración continua
├── package.json              # Scripts del workspace pnpm
└── pnpm-workspace.yaml
```

| Ruta | Responsabilidad |
| --- | --- |
| `backend/` | API HTTP con FastAPI. `POST /pins/presign-url` firma la subida a S3. `handler` en `main.py` adapta la app a AWS Lambda mediante Mangum. |
| `frontend/` | Interfaz React. El formulario de un pin pide la URL firmada y sube la imagen directo al bucket. |
| `infra/` | Script que crea el bucket de originales y el CORS que permite esa subida desde el navegador. |
| `.github/workflows/` | Definiciones de CI. El directorio queda reservado para los pipelines del equipo. |

## Requisitos

- Python 3.10 o superior
- Node.js 22 o superior
- pnpm 12 (`corepack enable` y `corepack prepare pnpm@12.11.2 --activate`)
- AWS CLI. `aws configure` tiene que hacerse en el mismo entorno donde corre la API

## Backend

La API firma la subida con las credenciales de AWS del proceso que la ejecuta. Si `aws configure` se hizo en Ubuntu (WSL), la API también se levanta ahí. El `.venv` de Windows no se reutiliza dentro de Ubuntu.

En Ubuntu, desde la raíz del repositorio (si el repo está en el disco de Windows, la ruta empieza por `/mnt/c/`):

```bash
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip
python3 -m venv ~/pinwatch-venv
~/pinwatch-venv/bin/pip install -r backend/requirements.txt
aws configure
python3 infra/setup_originals_bucket.py
~/pinwatch-venv/bin/uvicorn main:app --app-dir backend --host 127.0.0.1 --port 8000
```

El script del bucket se corre una vez. Crea `pinwatch-originals-<cuenta>`, o el nombre que tenga `ORIGINALS_BUCKET`, y deja el prefijo `originals/` listo para la subida directa.

Si `aws configure` se ejecutó en una sesión con `$HOME` vacío, las credenciales quedaron en `/.aws`. Arranca uvicorn así:

```bash
AWS_SHARED_CREDENTIALS_FILE=/.aws/credentials AWS_CONFIG_FILE=/.aws/config AWS_DEFAULT_REGION=us-east-1 ~/pinwatch-venv/bin/uvicorn main:app --app-dir backend --host 127.0.0.1 --port 8000
```

En Windows, cuando las credenciales están en Windows:

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r backend/requirements.txt
aws configure
python infra/setup_originals_bucket.py
uvicorn main:app --reload --app-dir backend --port 8000
```

Deja esa terminal abierta.

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

## Infraestructura de Luis Fernando: Secrets Manager y bastión EC2

Todo se crea con la AWS CLI desde scripts de bash en `infra/`. Cada script se puede correr varias veces: si el recurso ya existe, lo reusa. `teardown.sh` borra solo lo que crean estos scripts (recursos con las etiquetas `Project=pinwatch` y `Owner=luis-fernando`); no toca el bucket de originales ni la base de datos RDS.

| Servicio | Recurso | Para qué |
| --- | --- | --- |
| Secrets Manager | Secreto `pinwatch/app` | JSON con la configuración sensible: `jwt_signing_key` y `jwt_algorithm` (los genera `up.sh`) y los datos de la base `db_*` (los agrega quien crea la RDS). Nada de esto vive en el repo. |
| EC2 | Instancia `pinwatch-bastion` (`t3.micro`, Amazon Linux 2023, `LabInstanceProfile`, cliente `psql` 16) | Bastión para entrar a la RDS privada: consola, `psql` y túnel para migraciones. El flujo de la aplicación no depende de que esté prendida. |
| EC2 | Security group `pinwatch-bastion-sg` | Sin reglas de entrada. Se entra por Session Manager, no por SSH. |

Costo: la instancia cobra solo mientras está prendida (~USD 0.015/h con su IP pública); el disco de 8 GB y el secreto cobran aunque esté apagada (~USD 0.64 y 0.40 al mes). Con `teardown.sh` el costo queda en cero.

### Requisitos previos

- Learner Lab iniciado (indicador en verde).
- Las credenciales de **AWS Details** copiadas en `~/.aws/credentials` de Ubuntu (WSL): `aws_access_key_id`, `aws_secret_access_key` y `aws_session_token`.
- Región `us-east-1` (`aws configure set region us-east-1`). Los scripts se niegan a correr en otra.
- En Ubuntu: AWS CLI v2, `python3`, `openssl`, `curl` y [session-manager-plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-debian-and-ubuntu.html):

```bash
curl -fsSLo /tmp/smp.deb https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb
sudo dpkg -i /tmp/smp.deb
```

### Levantar, probar y bajar

En Ubuntu, desde la raíz del repositorio:

```bash
bash infra/check_lab.sh          # 1. el lab permite lo necesario (no deja nada creado)
bash infra/up.sh                 # 2. crea o reusa el secreto y el bastión (~3 min la primera vez)
bash infra/verify.sh             # 3. comprueba que todo funciona
bash infra/teardown.sh --status  #    muestra qué existe, sin borrar
bash infra/teardown.sh           # 4. borra todo, pide confirmación (--yes para no preguntar)
```

Cada servicio también se maneja por separado: `bash infra/secrets.sh up|status|down` y `bash infra/ec2.sh up|status|down` (`down` acepta `--yes`).

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
