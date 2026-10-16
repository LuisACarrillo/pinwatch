import json
from io import BytesIO
from urllib.parse import quote_plus

import boto3
import pytest
from moto import mock_aws
from PIL import Image

from image_processor import events, handler

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


@pytest.fixture
def topic(s3, monkeypatch):
    """Tópico SNS con una cola SQS suscrita; devuelve una función que lee lo publicado."""
    sns = boto3.client("sns", region_name="us-east-1")
    sqs = boto3.client("sqs", region_name="us-east-1")
    topic_arn = sns.create_topic(Name="pinwatch-events")["TopicArn"]
    queue_url = sqs.create_queue(QueueName="pinwatch-events-test")["QueueUrl"]
    queue_arn = sqs.get_queue_attributes(QueueUrl=queue_url, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
    sns.subscribe(TopicArn=topic_arn, Protocol="sqs", Endpoint=queue_arn)
    monkeypatch.setenv("SNS_TOPIC_ARN", topic_arn)
    monkeypatch.setattr(events, "_sns", sns)

    def published() -> list[dict]:
        messages = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10).get("Messages", [])
        return [json.loads(m["Body"]) for m in messages]

    return published


def keys(client, bucket: str) -> list[str]:
    return sorted(item["Key"] for item in client.list_objects_v2(Bucket=bucket).get("Contents", []))


def logged_events(caplog) -> list[dict]:
    own = (r for r in caplog.records if r.name in ("root", "image_processor.events"))
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

    # Sin SNS_TOPIC_ARN el resultado solo queda en el log.
    logged = logged_events(caplog)
    assert {"evento_sin_topico", "imagen_procesada"} <= {e["event"] for e in logged}
    pending = next(e for e in logged if e["event"] == "evento_sin_topico")
    assert pending["data"]["status"] == "processed"
    assert pending["data"]["thumbnail_key"] == "thumbnails/abc/foto de playa.webp"


def test_processed_image_is_published_to_sns(s3, topic):
    data = make_jpeg()
    s3.put_object(Bucket=ORIGINALS, Key="originals/abc/foto.jpg", Body=data)

    handler.handler(s3_event("originals/abc/foto.jpg", len(data)), None)

    [notification] = topic()
    assert notification["MessageAttributes"]["event_type"]["Value"] == "imagen_procesada"
    message = json.loads(notification["Message"])
    assert message["event_type"] == "imagen_procesada"
    assert message["data"] == {
        "object_key": "originals/abc/foto.jpg",
        "status": "processed",
        "processed_key": "processed/abc/foto.webp",
        "thumbnail_key": "thumbnails/abc/foto.webp",
    }


def test_rejected_image_is_published_to_sns(s3, topic):
    body = b"no soy una imagen"
    s3.put_object(Bucket=ORIGINALS, Key="originals/abc/falsa.jpg", Body=body)

    handler.handler(s3_event("originals/abc/falsa.jpg", len(body)), None)

    [notification] = topic()
    message = json.loads(notification["Message"])
    assert message["event_type"] == "imagen_rechazada"
    assert message["data"] == {"object_key": "originals/abc/falsa.jpg", "status": "rejected", "reason": "not_an_image"}


def test_sns_error_is_raised_for_retry(s3, topic, monkeypatch):
    from botocore.exceptions import ClientError

    def failing_publish(**kwargs):
        raise ClientError({"Error": {"Code": "Throttling", "Message": "Reduce la tasa"}}, "Publish")

    monkeypatch.setattr(events.sns(), "publish", failing_publish)
    data = make_jpeg()
    s3.put_object(Bucket=ORIGINALS, Key="originals/abc/foto.jpg", Body=data)

    with pytest.raises(ClientError):
        handler.handler(s3_event("originals/abc/foto.jpg", len(data)), None)


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
