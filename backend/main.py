import logging
import math
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal
from uuid import uuid4

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import Depends, FastAPI, HTTPException, Query, status
from fastapi.middleware.cors import CORSMiddleware
from mangum import Mangum
from pydantic import BaseModel, Field, field_validator

from app_secrets import SecretError
from auth import CurrentUser, get_current_user
from auth import router as auth_router
from image_processor.keys import InvalidImage, output_keys
import database
import image_events
import sns

logger = logging.getLogger(__name__)

app = FastAPI(
    title="PinWatch API",
    description="API de PinWatch para publicar, explorar y organizar pines, tableros y notificaciones.",
    version="0.2.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5173",
        "http://127.0.0.1:5173",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth_router)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


# ============================================================================
# Modelos Pydantic
# ============================================================================


class PresignPin(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    description: str = Field(default="", max_length=2000)
    category: str = Field(min_length=1, max_length=80)
    filename: str = Field(min_length=1, max_length=255)
    content_type: str = Field(min_length=1, max_length=120)

    @field_validator("title", "category", "filename")
    @classmethod
    def required_text(cls, value: str) -> str:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("Este campo es obligatorio.")
        return cleaned

    @field_validator("description")
    @classmethod
    def optional_text(cls, value: str) -> str:
        return value.strip()

    @field_validator("content_type")
    @classmethod
    def image_type(cls, value: str) -> str:
        content_type = value.strip()
        if not content_type.lower().startswith("image/"):
            raise ValueError("El archivo tiene que ser una imagen.")
        return content_type


class PresignUrl(BaseModel):
    url: str
    key: str
    content_type: str


class UserResponse(BaseModel):
    id: str
    username: str
    email: str
    created_at: datetime


class PinCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    description: str = Field(default="", max_length=2000)
    category: str = Field(min_length=1, max_length=80)
    object_key: str = Field(min_length=1, max_length=512)


class PinResponse(BaseModel):
    id: str
    user_id: str
    title: str
    description: str
    category: str
    object_key: str
    likes_count: int = 0
    created_at: datetime
    # Flujo 2: pending hasta que la Lambda termina; las llaves son del bucket processed.
    status: Literal["pending", "processed", "rejected"] = "pending"
    processed_key: str | None = None
    thumbnail_key: str | None = None
    thumbnail_url: str | None = None


class PaginatedFeed(BaseModel):
    items: list[PinResponse]
    total: int
    page: int
    limit: int
    total_pages: int


class LikeResponse(BaseModel):
    pin_id: str
    likes_count: int
    message: str


class NotificationResponse(BaseModel):
    id: str
    user_id: str
    pin_id: str
    message: str
    created_at: datetime


class BoardCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    description: str = Field(default="", max_length=1000)


class BoardUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=100)
    description: str | None = Field(default=None, max_length=1000)


class BoardResponse(BaseModel):
    id: str
    user_id: str
    name: str
    description: str
    created_at: datetime
    pins_count: int = 0


class BoardDetailResponse(BaseModel):
    id: str
    user_id: str
    name: str
    description: str
    created_at: datetime
    pins: list[PinResponse] = []


class AddPinToBoard(BaseModel):
    pin_id: str = Field(min_length=1, max_length=36)


# ============================================================================
# S3 Presigned URLs
# ============================================================================

_originals_bucket: str | None = None
_processed_bucket: str | None = None


def originals_bucket() -> str:
    global _originals_bucket
    if _originals_bucket:
        return _originals_bucket

    configured = os.environ.get("ORIGINALS_BUCKET", "").strip()
    if configured:
        _originals_bucket = configured
        return _originals_bucket

    try:
        account = boto3.client("sts").get_caller_identity()["Account"]
    except (BotoCoreError, ClientError) as error:
        raise HTTPException(
            status_code=503,
            detail="No se pudieron leer las credenciales de AWS.",
        ) from error

    _originals_bucket = f"pinwatch-originals-{account}"
    return _originals_bucket


def processed_bucket() -> str:
    global _processed_bucket
    if _processed_bucket:
        return _processed_bucket

    configured = os.environ.get("PROCESSED_BUCKET", "").strip()
    if configured:
        _processed_bucket = configured
        return _processed_bucket

    try:
        account = boto3.client("sts").get_caller_identity()["Account"]
    except (BotoCoreError, ClientError) as error:
        raise HTTPException(
            status_code=503,
            detail="No se pudieron leer las credenciales de AWS.",
        ) from error

    _processed_bucket = f"pinwatch-processed-{account}"
    return _processed_bucket


def thumbnail_url(key: str | None) -> str | None:
    if not key:
        return None
    try:
        return s3_client().generate_presigned_url(
            "get_object",
            Params={"Bucket": processed_bucket(), "Key": key},
            ExpiresIn=900,
        )
    except (BotoCoreError, ClientError, HTTPException) as error:
        logger.warning("No se pudo firmar la miniatura %s: %s", key, error)
        return None


def with_thumbnail_url(pin: dict[str, Any]) -> dict[str, Any]:
    signed = dict(pin)
    signed["thumbnail_url"] = thumbnail_url(signed.get("thumbnail_key"))
    return signed


def object_key(filename: str) -> str:
    name = re.sub(r"[^A-Za-z0-9._-]", "_", Path(filename).name).strip("._") or "image"
    return f"originals/{uuid4()}/{name}"


def s3_client():
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    config = Config(
        signature_version="s3v4",
        request_checksum_calculation="when_required",
        response_checksum_validation="when_required",
    )
    if region:
        return boto3.client("s3", region_name=region, config=config)
    return boto3.client("s3", config=config)


@app.post("/pins/presign-url", response_model=PresignUrl)
def presign_pin_upload(pin: PresignPin, current_user: CurrentUser = Depends(get_current_user)) -> PresignUrl:
    key = object_key(pin.filename)
    try:
        url = s3_client().generate_presigned_url(
            "put_object",
            Params={
                "Bucket": originals_bucket(),
                "Key": key,
                "ContentType": pin.content_type,
            },
            ExpiresIn=900,
        )
    except (BotoCoreError, ClientError) as error:
        raise HTTPException(
            status_code=502,
            detail="No se pudo firmar la subida.",
        ) from error

    return PresignUrl(url=url, key=key, content_type=pin.content_type)


# ============================================================================
# Usuarios (el registro y el login están en auth.py: /auth/register, /auth/login, /auth/me)
# ============================================================================


@app.get("/users/{user_id}", response_model=UserResponse)
def get_user(user_id: str) -> dict[str, Any]:
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT id, username, email, created_at FROM users WHERE id = %s;", (user_id,))
                user = cur.fetchone()
                if not user:
                    raise HTTPException(status_code=404, detail="Usuario no encontrado.")
                return dict(user)
    except HTTPException:
        raise
    except Exception as err:
        raise HTTPException(status_code=500, detail=f"Error al consultar usuario: {err}") from err


# ============================================================================
# Pines y Consulta Paginada del Feed
# ============================================================================


@app.post("/pins", response_model=PinResponse, status_code=status.HTTP_201_CREATED)
def create_pin(pin: PinCreate, current_user: CurrentUser = Depends(get_current_user)) -> dict[str, Any]:
    pin_id = str(uuid4())
    now = datetime.now(timezone.utc)
    # Las mismas llaves que escribe la Lambda del Flujo 2; existen en S3 cuando status es processed.
    try:
        processed_key, thumbnail_key = output_keys(pin.object_key)
    except InvalidImage:
        processed_key = thumbnail_key = None
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO pins (id, user_id, title, description, category, object_key, likes_count, created_at,
                                      processed_key, thumbnail_key)
                    VALUES (%s, %s, %s, %s, %s, %s, 0, %s, %s, %s)
                    RETURNING id, user_id, title, description, category, object_key, likes_count, created_at,
                              status, processed_key, thumbnail_key;
                    """,
                    (
                        pin_id,
                        current_user.id,
                        pin.title,
                        pin.description,
                        pin.category,
                        pin.object_key,
                        now,
                        processed_key,
                        thumbnail_key,
                    ),
                )
                row = cur.fetchone()
    except SecretError as err:
        raise HTTPException(status_code=503, detail=str(err)) from err
    except Exception as err:
        raise HTTPException(status_code=500, detail=f"Error al guardar pin: {err}") from err

    result = dict(row)
    # Notificación asíncrona a SNS
    sns.publish_event(
        event_type="pin.created",
        payload={
            "pin_id": result["id"],
            "user_id": result["user_id"],
            "title": result["title"],
            "category": result["category"],
        },
        subject=f"PinWatch: Nuevo pin en {result['category']}",
    )
    return with_thumbnail_url(result)


@app.get("/feed", response_model=PaginatedFeed)
@app.get("/pins", response_model=PaginatedFeed)
def get_feed(
    page: int = Query(1, ge=1, description="Número de página"),
    limit: int = Query(20, ge=1, le=100, description="Cantidad de publicaciones por página"),
    category: str | None = Query(None, description="Filtrar por categoría opcional"),
) -> PaginatedFeed:
    """Consulta paginada del feed de publicaciones con filtro opcional de categoría."""
    offset = (page - 1) * limit
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                if category:
                    cur.execute("SELECT COUNT(*) AS total FROM pins WHERE category = %s;", (category,))
                    total = cur.fetchone()["total"]

                    cur.execute(
                        """
                        SELECT id, user_id, title, description, category, object_key, likes_count, created_at,
                               status, processed_key, thumbnail_key
                        FROM pins
                        WHERE category = %s
                        ORDER BY created_at DESC
                        LIMIT %s OFFSET %s;
                        """,
                        (category, limit, offset),
                    )
                else:
                    cur.execute("SELECT COUNT(*) AS total FROM pins;")
                    total = cur.fetchone()["total"]

                    cur.execute(
                        """
                        SELECT id, user_id, title, description, category, object_key, likes_count, created_at,
                               status, processed_key, thumbnail_key
                        FROM pins
                        ORDER BY created_at DESC
                        LIMIT %s OFFSET %s;
                        """,
                        (limit, offset),
                    )

                rows = cur.fetchall()
    except SecretError as err:
        raise HTTPException(status_code=503, detail=str(err)) from err
    except Exception as err:
        raise HTTPException(status_code=500, detail=f"Error al consultar el feed: {err}") from err

    items = [PinResponse(**with_thumbnail_url(row)) for row in rows]
    total_pages = math.ceil(total / limit) if total > 0 else 1

    return PaginatedFeed(
        items=items,
        total=total,
        page=page,
        limit=limit,
        total_pages=total_pages,
    )


@app.get("/pins/{pin_id}", response_model=PinResponse)
def get_pin(pin_id: str) -> dict[str, Any]:
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT id, user_id, title, description, category, object_key, likes_count, created_at,
                           status, processed_key, thumbnail_key
                    FROM pins
                    WHERE id = %s;
                    """,
                    (pin_id,),
                )
                pin = cur.fetchone()
                if not pin:
                    raise HTTPException(status_code=404, detail="Pin no encontrado.")
                return with_thumbnail_url(pin)
    except HTTPException:
        raise
    except Exception as err:
        raise HTTPException(status_code=500, detail=f"Error al consultar pin: {err}") from err


# ============================================================================
# Likes y Notificaciones (con integración Amazon SNS)
# ============================================================================


@app.post("/pins/{pin_id}/like", response_model=LikeResponse)
def like_pin(pin_id: str, current_user: CurrentUser = Depends(get_current_user)) -> LikeResponse:
    """Registra un like en el pin, crea una notificación para su dueño y emite un evento SNS."""
    notification_id = str(uuid4())
    now = datetime.now(timezone.utc)

    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                # 1. Incrementar contador de likes
                cur.execute(
                    """
                    UPDATE pins
                    SET likes_count = likes_count + 1
                    WHERE id = %s
                    RETURNING id, user_id, title, likes_count;
                    """,
                    (pin_id,),
                )
                pin = cur.fetchone()
                if not pin:
                    raise HTTPException(status_code=404, detail="Pin no encontrado.")

                # 2. Registrar notificación para el autor del pin (solo campos indispensables)
                message = f"A alguien le gustó tu publicación '{pin['title']}'."
                cur.execute(
                    """
                    INSERT INTO notifications (id, user_id, pin_id, message, created_at)
                    VALUES (%s, %s, %s, %s, %s);
                    """,
                    (notification_id, pin["user_id"], pin["id"], message, now),
                )
    except HTTPException:
        raise
    except SecretError as err:
        raise HTTPException(status_code=503, detail=str(err)) from err
    except Exception as err:
        raise HTTPException(status_code=500, detail=f"Error al registrar like: {err}") from err

    # 3. Notificación asíncrona de eventos vía Amazon SNS
    sns.publish_event(
        event_type="pin.liked",
        payload={
            "pin_id": pin["id"],
            "user_id": pin["user_id"],
            "likes_count": pin["likes_count"],
        },
        subject=f"PinWatch: Nuevo like en '{pin['title']}'",
    )

    return LikeResponse(
        pin_id=pin["id"],
        likes_count=pin["likes_count"],
        message="Like registrado exitosamente.",
    )


@app.get("/notifications", response_model=list[NotificationResponse])
def get_notifications(
    limit: int = Query(50, ge=1, le=100),
    current_user: CurrentUser = Depends(get_current_user),
) -> list[NotificationResponse]:
    """Consulta las notificaciones del usuario del token."""
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT id, user_id, pin_id, message, created_at
                    FROM notifications
                    WHERE user_id = %s
                    ORDER BY created_at DESC
                    LIMIT %s;
                    """,
                    (current_user.id, limit),
                )
                rows = cur.fetchall()
                return [NotificationResponse(**row) for row in rows]
    except Exception as err:
        raise HTTPException(status_code=500, detail=f"Error al consultar notificaciones: {err}") from err


# ============================================================================
# Gestión de Tableros (Boards)
# ============================================================================


def _require_board_owner(cur, board_id: str, user_id: str) -> dict[str, Any]:
    """Devuelve el tablero si es de user_id; 404 si no existe y 403 si es de otro usuario."""
    cur.execute("SELECT id, user_id, name, description, created_at FROM boards WHERE id = %s;", (board_id,))
    board = cur.fetchone()
    if not board:
        raise HTTPException(status_code=404, detail="Tablero no encontrado.")
    if board["user_id"] != user_id:
        raise HTTPException(status_code=403, detail="Solo el dueño puede modificar este tablero.")
    return board


@app.post("/boards", response_model=BoardResponse, status_code=status.HTTP_201_CREATED)
def create_board(board: BoardCreate, current_user: CurrentUser = Depends(get_current_user)) -> dict[str, Any]:
    board_id = str(uuid4())
    now = datetime.now(timezone.utc)
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO boards (id, user_id, name, description, created_at)
                    VALUES (%s, %s, %s, %s, %s)
                    RETURNING id, user_id, name, description, created_at;
                    """,
                    (board_id, current_user.id, board.name, board.description, now),
                )
                row = cur.fetchone()
                result = dict(row)
                result["pins_count"] = 0
                return result
    except SecretError as err:
        raise HTTPException(status_code=503, detail=str(err)) from err
    except Exception as err:
        raise HTTPException(status_code=500, detail=f"Error al crear tablero: {err}") from err


@app.get("/boards", response_model=list[BoardResponse])
def list_boards(
    user_id: str | None = Query(None, description="Filtrar tableros por usuario"),
    limit: int = Query(50, ge=1, le=100),
    offset: int = Query(0, ge=0),
) -> list[dict[str, Any]]:
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                if user_id:
                    cur.execute(
                        """
                        SELECT b.id, b.user_id, b.name, b.description, b.created_at,
                               COUNT(bp.pin_id) AS pins_count
                        FROM boards b
                        LEFT JOIN board_pins bp ON b.id = bp.board_id
                        WHERE b.user_id = %s
                        GROUP BY b.id
                        ORDER BY b.created_at DESC
                        LIMIT %s OFFSET %s;
                        """,
                        (user_id, limit, offset),
                    )
                else:
                    cur.execute(
                        """
                        SELECT b.id, b.user_id, b.name, b.description, b.created_at,
                               COUNT(bp.pin_id) AS pins_count
                        FROM boards b
                        LEFT JOIN board_pins bp ON b.id = bp.board_id
                        GROUP BY b.id
                        ORDER BY b.created_at DESC
                        LIMIT %s OFFSET %s;
                        """,
                        (limit, offset),
                    )
                rows = cur.fetchall()
                return [dict(r) for r in rows]
    except SecretError as err:
        raise HTTPException(status_code=503, detail=str(err)) from err
    except Exception as err:
        raise HTTPException(status_code=500, detail=f"Error al listar tableros: {err}") from err


@app.get("/boards/{board_id}", response_model=BoardDetailResponse)
def get_board(board_id: str) -> dict[str, Any]:
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, user_id, name, description, created_at FROM boards WHERE id = %s;",
                    (board_id,),
                )
                board = cur.fetchone()
                if not board:
                    raise HTTPException(status_code=404, detail="Tablero no encontrado.")

                cur.execute(
                    """
                    SELECT p.id, p.user_id, p.title, p.description, p.category, p.object_key, p.likes_count, p.created_at,
                           p.status, p.processed_key, p.thumbnail_key
                    FROM pins p
                    JOIN board_pins bp ON p.id = bp.pin_id
                    WHERE bp.board_id = %s
                    ORDER BY bp.created_at DESC;
                    """,
                    (board_id,),
                )
                pins = cur.fetchall()
                result = dict(board)
                result["pins"] = [with_thumbnail_url(p) for p in pins]
                return result
    except HTTPException:
        raise
    except Exception as err:
        raise HTTPException(status_code=500, detail=f"Error al obtener tablero: {err}") from err


@app.put("/boards/{board_id}", response_model=BoardResponse)
def update_board(
    board_id: str, board_update: BoardUpdate, current_user: CurrentUser = Depends(get_current_user)
) -> dict[str, Any]:
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                current = _require_board_owner(cur, board_id, current_user.id)

                new_name = board_update.name if board_update.name is not None else current["name"]
                new_desc = board_update.description if board_update.description is not None else current["description"]

                cur.execute(
                    """
                    UPDATE boards
                    SET name = %s, description = %s
                    WHERE id = %s
                    RETURNING id, user_id, name, description, created_at;
                    """,
                    (new_name, new_desc, board_id),
                )
                updated = dict(cur.fetchone())

                cur.execute("SELECT COUNT(*) AS pins_count FROM board_pins WHERE board_id = %s;", (board_id,))
                updated["pins_count"] = cur.fetchone()["pins_count"]
                return updated
    except HTTPException:
        raise
    except Exception as err:
        raise HTTPException(status_code=500, detail=f"Error al actualizar tablero: {err}") from err


@app.delete("/boards/{board_id}")
def delete_board(board_id: str, current_user: CurrentUser = Depends(get_current_user)) -> dict[str, Any]:
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                _require_board_owner(cur, board_id, current_user.id)
                cur.execute("DELETE FROM boards WHERE id = %s;", (board_id,))
                return {"message": "Tablero eliminado exitosamente.", "id": board_id}
    except HTTPException:
        raise
    except Exception as err:
        raise HTTPException(status_code=500, detail=f"Error al eliminar tablero: {err}") from err


@app.post("/boards/{board_id}/pins")
def add_pin_to_board_post(
    board_id: str, payload: AddPinToBoard, current_user: CurrentUser = Depends(get_current_user)
) -> dict[str, Any]:
    return _add_pin_to_board(board_id, payload.pin_id, current_user.id)


@app.post("/boards/{board_id}/pins/{pin_id}")
def add_pin_to_board_param(
    board_id: str, pin_id: str, current_user: CurrentUser = Depends(get_current_user)
) -> dict[str, Any]:
    return _add_pin_to_board(board_id, pin_id, current_user.id)


def _add_pin_to_board(board_id: str, pin_id: str, user_id: str) -> dict[str, Any]:
    now = datetime.now(timezone.utc)
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                _require_board_owner(cur, board_id, user_id)

                cur.execute("SELECT id FROM pins WHERE id = %s;", (pin_id,))
                if not cur.fetchone():
                    raise HTTPException(status_code=404, detail="Pin no encontrado.")

                cur.execute(
                    """
                    INSERT INTO board_pins (board_id, pin_id, created_at)
                    VALUES (%s, %s, %s)
                    ON CONFLICT (board_id, pin_id) DO NOTHING;
                    """,
                    (board_id, pin_id, now),
                )
    except HTTPException:
        raise
    except Exception as err:
        raise HTTPException(status_code=500, detail=f"Error al agregar pin al tablero: {err}") from err

    sns.publish_event(
        event_type="board.pin_added",
        payload={"board_id": board_id, "pin_id": pin_id},
        subject="PinWatch: Pin agregado a tablero",
    )

    return {
        "message": "Pin agregado al tablero exitosamente.",
        "board_id": board_id,
        "pin_id": pin_id,
    }


@app.delete("/boards/{board_id}/pins/{pin_id}")
def remove_pin_from_board(
    board_id: str, pin_id: str, current_user: CurrentUser = Depends(get_current_user)
) -> dict[str, Any]:
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                _require_board_owner(cur, board_id, current_user.id)
                cur.execute(
                    "DELETE FROM board_pins WHERE board_id = %s AND pin_id = %s RETURNING pin_id;",
                    (board_id, pin_id),
                )
                deleted = cur.fetchone()
                if not deleted:
                    raise HTTPException(status_code=404, detail="El pin no pertenece a este tablero.")
                return {
                    "message": "Pin removido del tablero exitosamente.",
                    "board_id": board_id,
                    "pin_id": pin_id,
                }
    except HTTPException:
        raise
    except Exception as err:
        raise HTTPException(status_code=500, detail=f"Error al remover pin del tablero: {err}") from err


# Punto de entrada de AWS Lambda (API Gateway, Function URL o ALB).
_http_handler = Mangum(app)


def handler(event, context):
    # El tópico pinwatch-events invoca la misma Lambda con el resultado del Flujo 2.
    if image_events.is_sns_event(event):
        return image_events.handle_sns_event(event)
    return _http_handler(event, context)
