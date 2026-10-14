# PinWatch

PinWatch es una red social visual para comunidades creativas, diseñadores y usuarios que quieren descubrir, compartir y organizar imágenes en tableros temáticos. Cada publicación es un pin: título, descripción, categoría e imagen. Desde el muro se explora el contenido por categorías y se guarda en tableros personales.

Hoy ese tipo de uso choca con plataformas autohospedadas lentas. Subir archivos pesados y, al mismo tiempo, consultar un feed de imágenes satura el servidor y degrada la experiencia. PinWatch se diseña en la nube para separar esas cargas: la interfaz habla con una API que escala bajo demanda, el archivo viaja directo al almacenamiento de objetos y el trabajo pesado —comprimir la imagen y generar la miniatura del feed— ocurre en segundo plano, sin bloquear la respuesta al usuario.

El resultado esperado es un muro fluido, tableros que se actualizan al guardar un pin y un repositorio de imágenes disponible aunque el volumen de contenido y de consultas crezca.

## Estructura del monorepo

El repositorio separa la API, la interfaz y los pipelines. El frontend se gestiona con pnpm; el backend es una aplicación Python independiente.

```text
pinwatch/
├── backend/                  # API FastAPI, empaquetable en AWS Lambda
│   ├── main.py               # App, GET /health y handler de Mangum
│   └── requirements.txt
├── frontend/                 # Aplicación React con Vite
│   └── src/
│       ├── components/       # Componentes de interfaz
│       └── services/         # Cliente de la API
├── .github/workflows/        # Pipelines de integración continua
├── package.json              # Scripts del workspace pnpm
└── pnpm-workspace.yaml
```

| Ruta | Responsabilidad |
| --- | --- |
| `backend/` | API HTTP con FastAPI. `handler` en `main.py` adapta la app a AWS Lambda mediante Mangum. |
| `frontend/` | Interfaz React. `src/services` concentra las llamadas a la API y `src/components` la interfaz. |
| `.github/workflows/` | Definiciones de CI. El directorio queda reservado para los pipelines del equipo. |

## Requisitos

- Python 3.10 o superior
- Node.js 22 o superior
- pnpm 12 (`corepack enable` y `corepack prepare pnpm@12.11.2 --activate`)

## Backend

Desde la raíz del repositorio:

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r backend/requirements.txt
uvicorn main:app --reload --app-dir backend --port 8000
```

- Salud local: [http://localhost:8000/health](http://localhost:8000/health)
- Documentación interactiva: [http://localhost:8000/docs](http://localhost:8000/docs)
- Handler de Lambda: `main.handler`

## Frontend

Desde la raíz del repositorio:

```powershell
pnpm install
pnpm dev
```

La aplicación queda en [http://localhost:5173](http://localhost:5173). La URL de la API se configura con `VITE_API_URL` (ver `frontend/.env.example`). Si no existe, el cliente usa `http://localhost:8000`.

Otros scripts del workspace:

```powershell
pnpm build
pnpm lint
pnpm preview
```
