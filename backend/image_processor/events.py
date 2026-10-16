"""Aviso del resultado al tópico SNS pinwatch-events. La Lambda no toca la base.

Usa el mismo sobre que backend/sns.py ({event_type, timestamp, data} y el atributo
event_type), así un suscriptor puede filtrar imagen_procesada e imagen_rechazada.
Quien guarda el estado en RDS es la API, suscrita al tópico (backend/image_events.py).
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3

logger = logging.getLogger(__name__)

_sns = None


def sns():
    global _sns
    if _sns is None:
        _sns = boto3.client("sns")
    return _sns


def publish(event_type: str, object_key: str, **data) -> str | None:
    """Publica el resultado y devuelve el MessageId. Sin SNS_TOPIC_ARN solo lo registra.

    Si SNS falla, el error se lanza: Lambda reintenta el evento una vez y, como las llaves
    de salida no cambian, el reintento sobrescribe en vez de duplicar.
    """
    topic_arn = os.environ.get("SNS_TOPIC_ARN", "").strip()
    body = {
        "event_type": event_type,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "data": {"object_key": object_key, **data},
    }
    if not topic_arn:
        logger.info(json.dumps({"event": "evento_sin_topico", **body}, ensure_ascii=False))
        return None

    message_id = sns().publish(
        TopicArn=topic_arn,
        Subject=f"PinWatch Event: {event_type}",
        Message=json.dumps(body, ensure_ascii=False),
        MessageAttributes={"event_type": {"DataType": "String", "StringValue": event_type}},
    )["MessageId"]
    logger.info(
        json.dumps(
            {"event": "evento_publicado", "event_type": event_type, "key": object_key, "message_id": message_id},
            ensure_ascii=False,
        )
    )
    return message_id
