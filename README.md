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
