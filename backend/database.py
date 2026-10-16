"""Conexión y utilidades para PostgreSQL en PinWatch.

Utiliza psycopg2 con RealDictCursor para devolver diccionarios Python directamente,
facilitando la validación y serialización con modelos Pydantic.
"""

from collections.abc import Generator
from contextlib import contextmanager
from typing import Any, Callable

import psycopg2
from psycopg2.extras import RealDictCursor

import app_secrets


def _default_connection_factory():
    settings = app_secrets.database_settings()
    return psycopg2.connect(
        host=settings["host"],
        port=settings["port"],
        dbname=settings["name"],
        user=settings["username"],
        password=settings["password"],
        cursor_factory=RealDictCursor,
    )


connection_factory: Callable[[], Any] = _default_connection_factory


@contextmanager
def get_db() -> Generator[Any, None, None]:
    """Administrador de contexto para conexiones a la base de datos.
    
    Abre una conexión, confirma (commit) en caso de éxito y revierte (rollback)
    si ocurre alguna excepción, cerrando siempre la conexión al finalizar.
    """
    conn = connection_factory()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
