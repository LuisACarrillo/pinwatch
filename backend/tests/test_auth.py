"""Registro, login, /auth/me, validación del token y rutas protegidas."""

import base64
import json
from datetime import datetime, timedelta, timezone

import jwt
import pytest

from conftest import TEST_JWT_KEY

PIN = {"title": "Atardecer", "category": "photography", "object_key": "originals/abc/atardecer.jpg"}


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def login(client, email="ana@example.com", password="contrasena-segura"):
    return client.post("/auth/login", json={"email": email, "password": password})


def test_register_hashes_the_password_and_returns_a_token(client, test_db):
    response = client.post(
        "/auth/register", json={"username": "ana", "email": "Ana@Example.com", "password": "contrasena-segura"}
    )

    assert response.status_code == 201
    body = response.json()
    assert body["token_type"] == "bearer"
    assert body["expires_in"] == 3600
    assert body["user"]["username"] == "ana"
    assert body["user"]["email"] == "ana@example.com"
    assert "password" not in body["user"] and "password_hash" not in body["user"]
    stored = test_db.execute("SELECT password_hash FROM users WHERE username = 'ana';").fetchone()[0]
    assert stored.startswith("$argon2id$")
    assert "contrasena-segura" not in stored


def test_duplicate_email_is_rejected(client, register):
    register("ana", "ana@example.com")

    response = client.post(
        "/auth/register", json={"username": "otra", "email": "ANA@example.com", "password": "contrasena-segura"}
    )

    assert response.status_code == 409
    assert response.json()["detail"] == "El email ya está registrado."


def test_duplicate_username_is_rejected(client, register):
    register("ana", "ana@example.com")

    response = client.post(
        "/auth/register", json={"username": "ana", "email": "otra@example.com", "password": "contrasena-segura"}
    )

    assert response.status_code == 409


def test_short_password_is_rejected(client):
    response = client.post("/auth/register", json={"username": "ana", "email": "ana@example.com", "password": "corta"})
    assert response.status_code == 422


def test_login_returns_a_token_for_me(client, register):
    user_id, _ = register("ana", "ana@example.com")

    response = login(client)

    assert response.status_code == 200
    token = response.json()["access_token"]
    me = client.get("/auth/me", headers=bearer(token))
    assert me.status_code == 200
    assert me.json()["id"] == user_id
    assert me.json()["email"] == "ana@example.com"


@pytest.mark.parametrize(
    ("email", "password"),
    [("ana@example.com", "contrasena-incorrecta"), ("nadie@example.com", "contrasena-segura")],
)
def test_wrong_credentials_get_the_same_401(client, register, email, password):
    register("ana", "ana@example.com")

    response = login(client, email, password)

    assert response.status_code == 401
    assert response.json()["detail"] == "Credenciales inválidas."


def test_me_without_token_is_401(client):
    response = client.get("/auth/me")

    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_expired_token_is_401(client, register):
    user_id, _ = register("ana", "ana@example.com")
    past = datetime.now(timezone.utc) - timedelta(hours=2)
    token = jwt.encode(
        {"sub": user_id, "username": "ana", "iat": past, "exp": past + timedelta(hours=1)}, TEST_JWT_KEY, "HS256"
    )

    response = client.get("/auth/me", headers=bearer(token))

    assert response.status_code == 401
    assert "venció" in response.json()["detail"]


def test_tampered_token_is_401(client, register):
    _, headers = register("ana", "ana@example.com")
    header, payload, signature = headers["Authorization"].removeprefix("Bearer ").split(".")
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    claims["sub"] = "otro-usuario"
    forged = base64.urlsafe_b64encode(json.dumps(claims).encode()).rstrip(b"=").decode()

    response = client.get("/auth/me", headers=bearer(f"{header}.{forged}.{signature}"))

    assert response.status_code == 401
    assert response.json()["detail"] == "Token inválido."


def test_token_signed_with_another_key_is_401(client, register):
    user_id, _ = register("ana", "ana@example.com")
    now = datetime.now(timezone.utc)
    token = jwt.encode({"sub": user_id, "iat": now, "exp": now + timedelta(hours=1)}, "x" * 64, "HS256")

    assert client.get("/auth/me", headers=bearer(token)).status_code == 401


def test_unsigned_token_is_401(client, register):
    user_id, _ = register("ana", "ana@example.com")
    now = datetime.now(timezone.utc)
    token = jwt.encode({"sub": user_id, "iat": now, "exp": now + timedelta(hours=1)}, None, algorithm="none")

    assert client.get("/auth/me", headers=bearer(token)).status_code == 401


def test_create_pin_without_token_is_401(client):
    response = client.post("/pins", json=PIN)

    assert response.status_code == 401
    assert client.get("/feed").json()["total"] == 0


def test_pin_owner_comes_from_the_token_not_the_body(client, register):
    user_id, headers = register("ana", "ana@example.com")

    response = client.post("/pins", json={**PIN, "user_id": "otro-usuario"}, headers=headers)

    assert response.status_code == 201
    assert response.json()["user_id"] == user_id


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("post", "/pins/presign-url"),
        ("post", "/pins/abc/like"),
        ("get", "/notifications"),
        ("post", "/boards"),
        ("put", "/boards/abc"),
        ("delete", "/boards/abc"),
        ("post", "/boards/abc/pins"),
        ("post", "/boards/abc/pins/def"),
        ("delete", "/boards/abc/pins/def"),
    ],
)
def test_write_routes_require_a_token(client, method, path):
    assert getattr(client, method)(path).status_code == 401


def test_read_routes_stay_open(client):
    assert client.get("/feed").status_code == 200
    assert client.get("/boards").status_code == 200
    assert client.get("/pins/no-existe").status_code == 404
    assert client.get("/boards/no-existe").status_code == 404


def test_notifications_only_show_the_token_user(client, register):
    _, owner = register("ana", "ana@example.com")
    _, fan = register("beto", "beto@example.com")
    pin_id = client.post("/pins", json=PIN, headers=owner).json()["id"]
    client.post(f"/pins/{pin_id}/like", headers=fan)

    assert len(client.get("/notifications", headers=owner).json()) == 1
    assert client.get("/notifications", headers=fan).json() == []


@pytest.fixture
def board_of_ana(client, register):
    _, owner = register("ana", "ana@example.com")
    _, other = register("beto", "beto@example.com")
    board_id = client.post("/boards", json={"name": "Tablero de Ana"}, headers=owner).json()["id"]
    pin_id = client.post("/pins", json=PIN, headers=owner).json()["id"]
    assert client.post(f"/boards/{board_id}/pins", json={"pin_id": pin_id}, headers=owner).status_code == 200
    return board_id, pin_id, owner, other


@pytest.mark.parametrize(
    ("method", "path", "body"),
    [
        ("put", "/boards/{board}", {"name": "Robado"}),
        ("delete", "/boards/{board}", None),
        ("post", "/boards/{board}/pins", {"pin_id": "{pin}"}),
        ("post", "/boards/{board}/pins/{pin}", None),
        ("delete", "/boards/{board}/pins/{pin}", None),
    ],
)
def test_only_the_owner_can_modify_a_board(client, board_of_ana, method, path, body):
    board_id, pin_id, _, other = board_of_ana
    url = path.format(board=board_id, pin=pin_id)
    kwargs = {"headers": other}
    if body is not None:
        kwargs["json"] = {k: v.format(pin=pin_id) for k, v in body.items()}

    response = client.request(method.upper(), url, **kwargs)

    assert response.status_code == 403
    assert response.json()["detail"] == "Solo el dueño puede modificar este tablero."
    detail = client.get(f"/boards/{board_id}").json()
    assert detail["name"] == "Tablero de Ana"
    assert [p["id"] for p in detail["pins"]] == [pin_id]
