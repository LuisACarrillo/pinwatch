import json
from io import BytesIO
from urllib.parse import quote_plus

import boto3
import pytest
from moto import mock_aws
from PIL import Image

from image_processor import handler

ORIGINALS = "pinwatch-originals-123456789012"
PROCESSED = "pinwatch-processed-123456789012"


def make_jpeg(size=(2000, 1500)) -> bytes:
    buffer = BytesIO()
    Image.new("RGB", size, (30, 120, 200)).save(buffer, format="JPEG")
    return buffer.getvalue()


def s3_event(key: str, size: int, bucket: str = ORIGINALS) -> dict:
    """Evento con la forma que manda S3 al crear un objeto (llave codificada como URL)."""
    return {
        "Records": [
            {
                "eventVersion": "2.1",
                "eventSource": "aws:s3",
                "awsRegion": "us-east-1",
                "eventName": "ObjectCreated:Put",
                "s3": {
                    "configurationId": "pinwatch-image-processor",
                    "bucket": {"name": bucket, "arn": f"arn:aws:s3:::{bucket}"},
                    "object": {"key": quote_plus(key, safe="/"), "size": size, "eTag": "x"},
                },
            }
        ]
    }


@pytest.fixture
def s3(monkeypatch):
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("PROCESSED_BUCKET", PROCESSED)
    with mock_aws():
        client = boto3.client("s3", region_name="us-east-1")
        client.create_bucket(Bucket=ORIGINALS)
        client.create_bucket(Bucket=PROCESSED)
        monkeypatch.setattr(handler, "_s3", client)
        yield client


def keys(client, bucket: str) -> list[str]:
    return sorted(item["Key"] for item in client.list_objects_v2(Bucket=bucket).get("Contents", []))


def logged_events(caplog) -> list[dict]:
    own = (r for r in caplog.records if r.name in ("root", "image_processor.pin_store"))
    return [json.loads(record.getMessage()) for record in own]


def test_valid_image_produces_processed_and_thumbnail(s3, caplog):
    caplog.set_level("INFO")
    data = make_jpeg()
    s3.put_object(Bucket=ORIGINALS, Key="originals/abc/foto de playa.jpg", Body=data)

    response = handler.handler(s3_event("originals/abc/foto de playa.jpg", len(data)), None)

    assert response["results"][0]["status"] == "processed"
    assert keys(s3, PROCESSED) == [
        "processed/abc/foto de playa.webp",
        "thumbnails/abc/foto de playa.webp",
    ]
    thumbnail = s3.get_object(Bucket=PROCESSED, Key="thumbnails/abc/foto de playa.webp")
    assert thumbnail["ContentType"] == "image/webp"
    assert thumbnail["Metadata"]["original-key"] == "originals/abc/foto de playa.jpg"
    assert Image.open(BytesIO(thumbnail["Body"].read())).size == (400, 300)

    events = logged_events(caplog)
    assert {"pin_pendiente_de_guardar", "imagen_procesada"} <= {e["event"] for e in events}
    pin = next(e for e in events if e["event"] == "pin_pendiente_de_guardar")
    assert pin["status"] == "processed"
    assert pin["thumbnail_key"] == "thumbnails/abc/foto de playa.webp"


def test_originals_bucket_is_never_written(s3):
    data = make_jpeg()
    s3.put_object(Bucket=ORIGINALS, Key="originals/abc/foto.jpg", Body=data)

    handler.handler(s3_event("originals/abc/foto.jpg", len(data)), None)

    assert keys(s3, ORIGINALS) == ["originals/abc/foto.jpg"]


def test_fake_image_is_rejected_without_raising(s3, caplog):
    caplog.set_level("INFO")
    body = b"no soy una imagen"
    s3.put_object(Bucket=ORIGINALS, Key="originals/abc/falsa.jpg", Body=body)

    response = handler.handler(s3_event("originals/abc/falsa.jpg", len(body)), None)

    assert response["results"][0] == {
        "key": "originals/abc/falsa.jpg",
        "status": "rejected",
        "reason": "not_an_image",
    }
    assert keys(s3, PROCESSED) == []
    rejected = next(e for e in logged_events(caplog) if e["event"] == "imagen_rechazada")
    assert rejected["reason"] == "not_an_image"


def test_oversized_event_is_rejected_before_downloading(s3):
    # No hay objeto en S3: si el handler intentara descargarlo, el resultado sería "missing".
    response = handler.handler(s3_event("originals/abc/enorme.jpg", 16 * 1024 * 1024), None)

    assert response["results"][0]["reason"] == "too_large"


def test_key_outside_originals_is_ignored(s3):
    response = handler.handler(s3_event("processed/abc/foto.webp", 100), None)

    assert response["results"][0]["status"] == "ignored"
    assert keys(s3, PROCESSED) == []


def test_same_bucket_as_target_is_ignored(s3, monkeypatch):
    monkeypatch.setenv("PROCESSED_BUCKET", ORIGINALS)
    data = make_jpeg()
    s3.put_object(Bucket=ORIGINALS, Key="originals/abc/foto.jpg", Body=data)

    response = handler.handler(s3_event("originals/abc/foto.jpg", len(data)), None)

    assert response["results"][0]["status"] == "ignored"
    assert keys(s3, ORIGINALS) == ["originals/abc/foto.jpg"]


def test_deleted_original_is_skipped(s3):
    response = handler.handler(s3_event("originals/abc/borrada.jpg", 1000), None)

    assert response["results"][0]["status"] == "missing"


def test_duplicate_event_overwrites_instead_of_duplicating(s3):
    data = make_jpeg()
    s3.put_object(Bucket=ORIGINALS, Key="originals/abc/foto.jpg", Body=data)
    event = s3_event("originals/abc/foto.jpg", len(data))

    handler.handler(event, None)
    handler.handler(event, None)

    assert keys(s3, PROCESSED) == ["processed/abc/foto.webp", "thumbnails/abc/foto.webp"]


def test_s3_test_event_is_accepted(s3):
    assert handler.handler({"Event": "s3:TestEvent", "Service": "Amazon S3"}, None) == {"results": []}


def test_transient_s3_error_is_raised_for_retry(s3, monkeypatch):
    from botocore.exceptions import ClientError

    def failing_get_object(**kwargs):
        raise ClientError({"Error": {"Code": "SlowDown", "Message": "Reduce la tasa"}}, "GetObject")

    monkeypatch.setattr(s3, "get_object", failing_get_object)

    with pytest.raises(ClientError):
        handler.handler(s3_event("originals/abc/foto.jpg", 1000), None)
