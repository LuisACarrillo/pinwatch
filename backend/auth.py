"""Autenticación con JWT: registro, login, usuario actual y la dependencia get_current_user.

Las contraseñas se guardan con Argon2id (argon2-cffi); el hash se hace siempre en el servidor.
Los tokens se firman con la llave de pinwatch/app (app_secrets.jwt_settings()) y expiran en
JWT_TTL_MINUTES (60 por defecto). No hay refresh token: al vencer, el usuario vuelve a iniciar sesión.
"""

import os
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from functools import cache
from typing import Any
from uuid import uuid4

import jwt
import psycopg2
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field, field_validator

import app_secrets
import database
from app_secrets import SecretError

DEFAULT_TTL_MINUTES = 60

router = APIRouter(prefix="/auth", tags=["auth"])
_hasher = PasswordHasher()
# auto_error=False: sin header se responde 401 (no el 403 por defecto de HTTPBearer).
_bearer = HTTPBearer(auto_error=False)


class RegisterRequest(BaseModel):
    username: str = Field(min_length=3, max_length=50, pattern=r"^[A-Za-z0-9_.-]+$")
    email: str = Field(min_length=3, max_length=255, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    password: str = Field(min_length=8, max_length=128)

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: str) -> str:
        return value.strip().lower()


class LoginRequest(BaseModel):
    email: str = Field(min_length=3, max_length=255)
    password: str = Field(min_length=1, max_length=128)

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: str) -> str:
        return value.strip().lower()


class AuthUser(BaseModel):
    id: str
    username: str
    email: str
    created_at: datetime


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int


class RegisterResponse(TokenResponse):
    user: AuthUser


@dataclass(frozen=True)
class CurrentUser:
    id: str
    username: str


def token_ttl() -> timedelta:
    return timedelta(minutes=int(os.environ.get("JWT_TTL_MINUTES", DEFAULT_TTL_MINUTES)))


def _signing_settings() -> tuple[str, str]:
    try:
        return app_secrets.jwt_settings()
    except SecretError as err:
        raise HTTPException(status_code=503, detail=str(err)) from err


def create_access_token(user_id: str, username: str) -> TokenResponse:
    key, algorithm = _signing_settings()
    now = datetime.now(timezone.utc)
    ttl = token_ttl()
    token = jwt.encode(
        {"sub": user_id, "username": username, "iat": now, "exp": now + ttl}, key, algorithm=algorithm
    )
    return TokenResponse(access_token=token, expires_in=int(ttl.total_seconds()))


def _unauthorized(detail: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED, detail=detail, headers={"WWW-Authenticate": "Bearer"}
    )


def get_current_user(credentials: HTTPAuthorizationCredentials | None = Depends(_bearer)) -> CurrentUser:
    """Usuario del token Bearer. 401 si falta, venció, está alterado o no usa el algoritmo configurado."""
    if credentials is None:
        raise _unauthorized("Falta el token de acceso.")
    key, algorithm = _signing_settings()
    try:
        # Solo se acepta el algoritmo configurado: así un token con alg=none u otro se rechaza.
        claims = jwt.decode(
            credentials.credentials, key, algorithms=[algorithm], options={"require": ["exp", "iat", "sub"]}
        )
    except jwt.ExpiredSignatureError as err:
        raise _unauthorized("El token venció; inicia sesión de nuevo.") from err
    except jwt.InvalidTokenError as err:
        raise _unauthorized("Token inválido.") from err
    return CurrentUser(id=claims["sub"], username=claims.get("username", ""))


@cache
def _dummy_hash() -> str:
    return _hasher.hash("pinwatch-usuario-inexistente")


def _verify_password(password_hash: str, password: str) -> bool:
    try:
        return _hasher.verify(password_hash, password)
    except (VerificationError, InvalidHashError):
        return False


@router.post("/register", response_model=RegisterResponse, status_code=status.HTTP_201_CREATED)
def register(payload: RegisterRequest) -> RegisterResponse:
    user_id = str(uuid4())
    now = datetime.now(timezone.utc)
    password_hash = _hasher.hash(payload.password)
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT email, username FROM users WHERE email = %s OR username = %s;",
                    (payload.email, payload.username),
                )
                existing = cur.fetchone()
                if existing:
                    detail = (
                        "El email ya está registrado."
                        if existing["email"] == payload.email
                        else "El nombre de usuario ya está en uso."
                    )
                    raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=detail)
                cur.execute(
                    """
                    INSERT INTO users (id, username, email, password_hash, created_at)
                    VALUES (%s, %s, %s, %s, %s)
                    RETURNING id, username, email, created_at;
                    """,
                    (user_id, payload.username, payload.email, password_hash, now),
                )
                user = dict(cur.fetchone())
    except HTTPException:
        raise
    except psycopg2.IntegrityError as err:
        # Dos registros simultáneos con el mismo email o username: gana el primero.
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="El email o el usuario ya existen.") from err
    except SecretError as err:
        raise HTTPException(status_code=503, detail=str(err)) from err

    token = create_access_token(user["id"], user["username"])
    return RegisterResponse(**token.model_dump(), user=AuthUser(**user))


@router.post("/login", response_model=TokenResponse)
def login(payload: LoginRequest) -> TokenResponse:
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, username, password_hash FROM users WHERE email = %s;", (payload.email,)
                )
                user = cur.fetchone()
                if user is None:
                    # Se verifica igual contra un hash falso: el tiempo de respuesta no revela qué emails existen.
                    _verify_password(_dummy_hash(), payload.password)
                    raise _unauthorized("Credenciales inválidas.")
                if not _verify_password(user["password_hash"], payload.password):
                    raise _unauthorized("Credenciales inválidas.")
                if _hasher.check_needs_rehash(user["password_hash"]):
                    cur.execute(
                        "UPDATE users SET password_hash = %s WHERE id = %s;",
                        (_hasher.hash(payload.password), user["id"]),
                    )
    except SecretError as err:
        raise HTTPException(status_code=503, detail=str(err)) from err
    return create_access_token(user["id"], user["username"])


@router.get("/me", response_model=AuthUser)
def me(current_user: CurrentUser = Depends(get_current_user)) -> dict[str, Any]:
    try:
        with database.get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, username, email, created_at FROM users WHERE id = %s;", (current_user.id,)
                )
                user = cur.fetchone()
    except SecretError as err:
        raise HTTPException(status_code=503, detail=str(err)) from err
    if user is None:
        raise _unauthorized("El usuario del token ya no existe.")
    return dict(user)
