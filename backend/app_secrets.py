"""Configuración sensible de PinWatch leída de AWS Secrets Manager.

El secreto (APP_SECRET_NAME, por defecto pinwatch/app) es un JSON con llaves
como jwt_signing_key, jwt_algorithm, db_host, db_port, db_name, db_username,
db_password o db_secret_arn.

Se lee una vez y se guarda en memoria APP_SECRET_TTL_SECONDS (300 por defecto),
así una Lambda caliente no consulta Secrets Manager en cada request.

En local, una variable de entorno con el nombre de la llave en mayúsculas
(JWT_SIGNING_KEY, DB_HOST, ...) tiene prioridad y evita llamar a AWS.

El módulo no se llama secrets.py para no tapar el módulo secrets de Python.
"""

import json
import os
import threading
import time
from collections.abc import Callable
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

DEFAULT_SECRET_NAME = "pinwatch/app"
DEFAULT_TTL_SECONDS = 300.0
DEFAULT_DB_PORT = "5432"


class SecretError(RuntimeError):
    """El secreto no se pudo leer o le falta un valor."""


def _secretsmanager_client():
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    if region:
        return boto3.client("secretsmanager", region_name=region)
    return boto3.client("secretsmanager")


class SecretCache:
    """Caché en memoria de secretos JSON, con expiración."""

    def __init__(
        self,
        client_factory: Callable[[], Any] = _secretsmanager_client,
        ttl_seconds: float | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if ttl_seconds is None:
            ttl_seconds = float(os.environ.get("APP_SECRET_TTL_SECONDS", DEFAULT_TTL_SECONDS))
        self._client_factory = client_factory
        self._client = None
        self._ttl = ttl_seconds
        self._clock = clock
        self._entries: dict[str, tuple[float, dict[str, Any]]] = {}
        self._lock = threading.Lock()

    def get_json(self, secret_id: str) -> dict[str, Any]:
        with self._lock:
            cached = self._entries.get(secret_id)
            if cached and self._clock() - cached[0] < self._ttl:
                return cached[1]

            if self._client is None:
                self._client = self._client_factory()
            try:
                response = self._client.get_secret_value(SecretId=secret_id)
            except (BotoCoreError, ClientError) as error:
                raise SecretError(f"No se pudo leer el secreto {secret_id}.") from error

            try:
                value = json.loads(response["SecretString"])
            except (KeyError, json.JSONDecodeError) as error:
                raise SecretError(f"El secreto {secret_id} no es un JSON válido.") from error
            if not isinstance(value, dict):
                raise SecretError(f"El secreto {secret_id} no es un JSON válido.")

            self._entries[secret_id] = (self._clock(), value)
            return value

    def clear(self) -> None:
        """Olvida lo guardado; útil si la base rechaza una contraseña que ya rotó."""
        with self._lock:
            self._entries.clear()


_cache = SecretCache()


def secret_name() -> str:
    return os.environ.get("APP_SECRET_NAME", "").strip() or DEFAULT_SECRET_NAME


def get_setting(key: str, default: str | None = None) -> str:
    """Valor de `key`: primero la variable de entorno KEY, luego el secreto."""
    from_env = os.environ.get(key.upper(), "").strip()
    if from_env:
        return from_env

    value = _cache.get_json(secret_name()).get(key)
    if value not in (None, ""):
        return str(value)
    if default is not None:
        return default
    raise SecretError(f"Falta {key} en el secreto {secret_name()} y en la variable {key.upper()}.")


def jwt_settings() -> tuple[str, str]:
    """Llave y algoritmo para firmar los JWT."""
    return get_setting("jwt_signing_key"), get_setting("jwt_algorithm", "HS256")


def database_settings() -> dict[str, str]:
    """Datos de conexión a PostgreSQL.

    Si RDS administra la contraseña (--manage-master-user-password), el secreto de la
    app guarda db_secret_arn y el usuario y la contraseña se leen de ese otro secreto,
    que RDS rota. Así nunca queda una copia vieja de la contraseña.
    """
    settings = {
        "host": get_setting("db_host"),
        "port": get_setting("db_port", DEFAULT_DB_PORT),
        "name": get_setting("db_name"),
    }

    username = get_setting("db_username", "")
    password = get_setting("db_password", "")
    if not (username and password):
        managed_arn = get_setting("db_secret_arn", "")
        if not managed_arn:
            raise SecretError(
                "Faltan las credenciales de la base: define db_username y db_password, "
                "o db_secret_arn si RDS administra la contraseña."
            )
        managed = _cache.get_json(managed_arn)
        username = username or str(managed.get("username", ""))
        password = str(managed.get("password", ""))
        if not (username and password):
            raise SecretError(f"El secreto {managed_arn} no trae username y password.")

    settings["username"] = username
    settings["password"] = password
    return settings


def clear_cache() -> None:
    _cache.clear()
