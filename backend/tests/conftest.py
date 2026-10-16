import sqlite3
from contextlib import contextmanager
import pytest
from argon2 import PasswordHasher
from fastapi.testclient import TestClient

import auth
import database
from main import app


SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS pins (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    category TEXT NOT NULL,
    object_key TEXT NOT NULL,
    likes_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processed', 'rejected')),
    processed_key TEXT,
    thumbnail_key TEXT
);

CREATE TABLE IF NOT EXISTS boards (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS board_pins (
    board_id TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
    pin_id TEXT NOT NULL REFERENCES pins(id) ON DELETE CASCADE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (board_id, pin_id)
);

CREATE TABLE IF NOT EXISTS notifications (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    pin_id TEXT NOT NULL REFERENCES pins(id) ON DELETE CASCADE,
    message TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);
"""


class SQLiteDictCursor:
    def __init__(self, cursor: sqlite3.Cursor):
        self._cur = cursor

    def execute(self, sql: str, params: tuple | list = ()):
        sql_converted = sql.replace("%s", "?")
        return self._cur.execute(sql_converted, params)

    @property
    def rowcount(self):
        return self._cur.rowcount

    def fetchone(self):
        row = self._cur.fetchone()
        return dict(row) if row is not None else None

    def fetchall(self):
        rows = self._cur.fetchall()
        return [dict(r) for r in rows]

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        pass


class SQLiteConnWrapper:
    def __init__(self, conn: sqlite3.Connection):
        self._conn = conn

    def cursor(self):
        return SQLiteDictCursor(self._conn.cursor())

    def commit(self):
        self._conn.commit()

    def rollback(self):
        self._conn.rollback()

    def close(self):
        pass


@pytest.fixture
def test_db(monkeypatch):
    conn = sqlite3.connect(":memory:", check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA_SQL)
    conn.commit()

    wrapper = SQLiteConnWrapper(conn)

    @contextmanager
    def mock_get_db():
        yield wrapper

    monkeypatch.setattr(database, "get_db", mock_get_db)
    yield conn
    conn.close()


TEST_JWT_KEY = "llave-de-prueba-" + "x" * 48


@pytest.fixture
def client(test_db, monkeypatch):
    # Llave JWT local: app_secrets la toma de la variable y no llama a Secrets Manager.
    monkeypatch.setenv("JWT_SIGNING_KEY", TEST_JWT_KEY)
    monkeypatch.setenv("JWT_ALGORITHM", "HS256")
    # Argon2id con parámetros mínimos para que las pruebas no tarden; producción usa los de argon2-cffi.
    monkeypatch.setattr(auth, "_hasher", PasswordHasher(time_cost=1, memory_cost=8, parallelism=1))
    return TestClient(app)


@pytest.fixture
def register(client):
    """Registra un usuario y devuelve (user_id, headers con su token Bearer)."""

    def _register(username: str, email: str, password: str = "contrasena-segura"):
        response = client.post("/auth/register", json={"username": username, "email": email, "password": password})
        assert response.status_code == 201, response.text
        body = response.json()
        return body["user"]["id"], {"Authorization": f"Bearer {body['access_token']}"}

    return _register
