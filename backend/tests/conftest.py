import sqlite3
from contextlib import contextmanager
import pytest
from fastapi.testclient import TestClient

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
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
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


@pytest.fixture
def client(test_db):
    return TestClient(app)
