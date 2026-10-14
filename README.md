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

## Infraestructura de Luis Fernando: Secrets Manager y EC2

Todo se crea con la AWS CLI desde scripts de bash en `infra/`. Cada script se puede correr varias veces: si el recurso ya existe, lo reusa. `teardown.sh` borra solo lo que crean estos scripts (recursos con las etiquetas `Project=pinwatch` y `Owner=luis-fernando`); no toca el bucket de originales ni la base de datos RDS.

| Servicio | Recurso | Para qué |
| --- | --- | --- |
| Secrets Manager | `pinwatch/jwt` | Llave de firma de los JWT (`jwt_signing_key`, `jwt_algorithm`). La API la lee al arrancar; nunca vive en el repo. |
| EC2 | Instancia `pinwatch-aux` (`t3.micro`, Amazon Linux 2023, `LabInstanceProfile`, key pair `vockey`) | Servicios auxiliares: aloja el runner de GitHub Actions que despliega. El flujo de la aplicación no depende de que esté prendida. |
| EC2 | Security group `pinwatch-aux-sg` | Solo SSH (22) desde la IP pública de quien corre `up.sh`. |

Costo: la instancia cobra solo mientras está prendida (~USD 0.015/h con su IP pública); el disco de 8 GB y el secreto cobran poco aunque esté apagada (~USD 0.64 y 0.40 al mes). Con `teardown.sh` el costo queda en cero.

### Requisitos previos

- Learner Lab iniciado (indicador en verde).
- Las credenciales de **AWS Details** copiadas en `~/.aws/credentials` de Ubuntu (WSL): `aws_access_key_id`, `aws_secret_access_key` y `aws_session_token`.
- Región `us-east-1` (`aws configure set region us-east-1`). Los scripts se niegan a correr en otra.
- `aws`, `openssl` y `curl` en Ubuntu.

### Levantar, revisar y bajar

En Ubuntu, desde la raíz del repositorio:

```bash
bash infra/up.sh                 # crea o reusa el secreto y la instancia
bash infra/teardown.sh --status  # muestra qué existe, sin borrar
bash infra/teardown.sh           # borra todo, pide confirmación
bash infra/teardown.sh --yes     # borra todo sin preguntar
```

Cada servicio también se maneja por separado: `bash infra/secrets.sh up|status|down` y `bash infra/ec2.sh up|status|down` (`down` acepta `--yes`).

### Variables de entorno

Todas son opcionales; los scripts leen la cuenta y la región de la sesión de la AWS CLI.

| Variable | Por defecto | Uso |
| --- | --- | --- |
| `JWT_SECRET_NAME` | `pinwatch/jwt` | Nombre del secreto de JWT. La API usará el mismo valor. |
| `EC2_INSTANCE_TYPE` | `t3.micro` | Tipo de la instancia auxiliar. |
| `SSH_CIDR` | Tu IP pública `/32` (de `checkip.amazonaws.com`) | Origen permitido para SSH. |

### Verificar que funciona

```bash
aws secretsmanager describe-secret --secret-id pinwatch/jwt --query '[Name, ARN]' --output text
# pinwatch/jwt   arn:aws:secretsmanager:us-east-1:<cuenta>:secret:pinwatch/jwt-XXXXXX

aws ec2 describe-instances --filters Name=tag:Name,Values=pinwatch-aux \
  --query 'Reservations[].Instances[].[InstanceId, State.Name, PublicIpAddress]' --output text
# i-0123456789abcdef0   running   3.80.x.x
```

Para entrar por SSH, descarga `labsuser.pem` desde **AWS Details** (es la llave de `vockey`):

```bash
cp /mnt/c/Users/<usuario>/Downloads/labsuser.pem ~/.ssh/ && chmod 400 ~/.ssh/labsuser.pem
ssh -i ~/.ssh/labsuser.pem ec2-user@<IP pública>
```

### Problemas comunes del Learner Lab

- **`Las credenciales no son válidas o vencieron` / `ExpiredToken`**: la sesión del lab dura unas 4 horas. Reinicia el lab y vuelve a copiar las tres líneas de **AWS Details** a `~/.aws/credentials`.
- **La instancia aparece en `stopped`**: el lab la apaga al terminar la sesión. `bash infra/up.sh` la vuelve a arrancar; la IP pública cambia cada vez.
- **SSH no responde**: tu IP cambió desde la última vez. `bash infra/up.sh` actualiza la regla del security group.
- **`DependencyViolation` al borrar el security group**: la interfaz de red de la instancia tardó en liberarse. Repite `bash infra/teardown.sh --yes` en un minuto.
- **`AccessDenied`**: la acción está restringida en Learner Lab. No uses otra cuenta ni otro rol; avisa al equipo.
