import json

import boto3
import pytest
from botocore.stub import Stubber

import app_secrets
from app_secrets import SecretCache, SecretError

APP_SECRET = "pinwatch/app"
RDS_SECRET = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-abc"
ENV_KEYS = [
    "APP_SECRET_NAME",
    "JWT_SIGNING_KEY",
    "JWT_ALGORITHM",
    "DB_HOST",
    "DB_PORT",
    "DB_NAME",
    "DB_USERNAME",
    "DB_PASSWORD",
    "DB_SECRET_ARN",
]


class FakeClock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


@pytest.fixture
def client():
    return boto3.client(
        "secretsmanager",
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
    )


@pytest.fixture
def stubber(client):
    with Stubber(client) as stub:
        yield stub
        stub.assert_no_pending_responses()


@pytest.fixture
def clock():
    return FakeClock()


@pytest.fixture(autouse=True)
def isolated(monkeypatch, client, clock):
    for key in ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    cache = SecretCache(client_factory=lambda: client, ttl_seconds=300, clock=clock)
    monkeypatch.setattr(app_secrets, "_cache", cache)


def expect_secret(stubber, secret_id, value):
    stubber.add_response(
        "get_secret_value",
        {"Name": secret_id, "SecretString": json.dumps(value)},
        {"SecretId": secret_id},
    )


def test_reads_jwt_settings_from_secret(stubber):
    expect_secret(stubber, APP_SECRET, {"jwt_signing_key": "llave", "jwt_algorithm": "HS512"})

    assert app_secrets.jwt_settings() == ("llave", "HS512")


def test_jwt_algorithm_defaults_to_hs256(stubber):
    expect_secret(stubber, APP_SECRET, {"jwt_signing_key": "llave"})

    assert app_secrets.jwt_settings() == ("llave", "HS256")


def test_caches_the_secret_within_ttl(stubber, clock):
    expect_secret(stubber, APP_SECRET, {"jwt_signing_key": "llave"})

    app_secrets.get_setting("jwt_signing_key")
    clock.now += 299
    # Un solo response en el stub: una segunda llamada a AWS fallaría.
    assert app_secrets.get_setting("jwt_signing_key") == "llave"


def test_reloads_the_secret_after_ttl(stubber, clock):
    expect_secret(stubber, APP_SECRET, {"jwt_signing_key": "vieja"})
    expect_secret(stubber, APP_SECRET, {"jwt_signing_key": "nueva"})

    assert app_secrets.get_setting("jwt_signing_key") == "vieja"
    clock.now += 301
    assert app_secrets.get_setting("jwt_signing_key") == "nueva"


def test_clear_cache_forces_a_new_read(stubber):
    expect_secret(stubber, APP_SECRET, {"jwt_signing_key": "vieja"})
    expect_secret(stubber, APP_SECRET, {"jwt_signing_key": "nueva"})

    app_secrets.get_setting("jwt_signing_key")
    app_secrets.clear_cache()
    assert app_secrets.get_setting("jwt_signing_key") == "nueva"


def test_environment_variable_wins_without_calling_aws(stubber, monkeypatch):
    monkeypatch.setenv("JWT_SIGNING_KEY", "llave-local")
    monkeypatch.setenv("JWT_ALGORITHM", "HS256")

    assert app_secrets.jwt_settings() == ("llave-local", "HS256")


def test_secret_name_comes_from_environment(stubber, monkeypatch):
    monkeypatch.setenv("APP_SECRET_NAME", "pinwatch/otro")
    expect_secret(stubber, "pinwatch/otro", {"jwt_signing_key": "llave"})

    assert app_secrets.get_setting("jwt_signing_key") == "llave"


def test_missing_key_raises_a_clear_error(stubber):
    expect_secret(stubber, APP_SECRET, {"jwt_algorithm": "HS256"})

    with pytest.raises(SecretError, match="Falta jwt_signing_key"):
        app_secrets.jwt_settings()


def test_aws_error_becomes_secret_error(stubber):
    stubber.add_client_error(
        "get_secret_value",
        service_error_code="AccessDeniedException",
        expected_params={"SecretId": APP_SECRET},
    )

    with pytest.raises(SecretError, match="No se pudo leer el secreto pinwatch/app"):
        app_secrets.get_setting("jwt_signing_key")


def test_non_json_secret_is_rejected(stubber):
    stubber.add_response(
        "get_secret_value",
        {"Name": APP_SECRET, "SecretString": "no es json"},
        {"SecretId": APP_SECRET},
    )

    with pytest.raises(SecretError, match="no es un JSON válido"):
        app_secrets.get_setting("jwt_signing_key")


def test_database_settings_with_password_in_app_secret(stubber):
    expect_secret(
        stubber,
        APP_SECRET,
        {
            "db_host": "pinwatch.abc.us-east-1.rds.amazonaws.com",
            "db_name": "pinwatch",
            "db_username": "pinwatch_app",
            "db_password": "contraseña",
        },
    )

    assert app_secrets.database_settings() == {
        "host": "pinwatch.abc.us-east-1.rds.amazonaws.com",
        "port": "5432",
        "name": "pinwatch",
        "username": "pinwatch_app",
        "password": "contraseña",
    }


def test_database_settings_follow_rds_managed_secret(stubber):
    expect_secret(
        stubber,
        APP_SECRET,
        {"db_host": "db.local", "db_port": 5433, "db_name": "pinwatch", "db_secret_arn": RDS_SECRET},
    )
    expect_secret(stubber, RDS_SECRET, {"username": "postgres", "password": "rotada"})

    settings = app_secrets.database_settings()

    assert settings["port"] == "5433"
    assert (settings["username"], settings["password"]) == ("postgres", "rotada")


def test_database_settings_without_credentials_fail(stubber):
    expect_secret(stubber, APP_SECRET, {"db_host": "db.local", "db_name": "pinwatch"})

    with pytest.raises(SecretError, match="Faltan las credenciales de la base"):
        app_secrets.database_settings()
