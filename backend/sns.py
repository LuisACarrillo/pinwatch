"""Integración con Amazon SNS para notificaciones asíncronas de eventos en PinWatch.

Publica eventos (como 'pin.liked', 'pin.created', etc.) a un tópico de Amazon SNS.
Si SNS_TOPIC_ARN no está configurado (por ejemplo, en desarrollo local sin SNS),
el módulo registra la acción sin interrumpir el flujo de la aplicación.
"""

import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

import app_secrets

logger = logging.getLogger(__name__)


def sns_client():
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    if region:
        return boto3.client("sns", region_name=region)
    return boto3.client("sns")


def get_topic_arn() -> str:
    """Obtiene el ARN del tópico SNS configurado vía variable de entorno o Secrets Manager."""
    from_env = os.environ.get("SNS_TOPIC_ARN", "").strip()
    if from_env:
        return from_env
    try:
        return app_secrets.sns_topic_arn()
    except Exception:
        return ""


def publish_event(event_type: str, payload: dict[str, Any], subject: str | None = None) -> dict[str, Any] | None:
    """Publica un mensaje con formato estándar en Amazon SNS.

    Args:
        event_type: Tipo de evento (ej. 'pin.liked', 'pin.created').
        payload: Datos asociados al evento.
        subject: Línea de asunto opcional para el mensaje SNS.

    Returns:
        Respuesta de SNS con MessageId si se publicó, o None si no hay tópico o falló.
    """
    topic_arn = get_topic_arn()
    if not topic_arn:
        logger.info("SNS_TOPIC_ARN no configurado; evento '%s' omitido en SNS.", event_type)
        return None

    client = sns_client()
    body = {
        "event_type": event_type,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "data": payload,
    }

    subject_line = (subject or f"PinWatch Event: {event_type}")[:100]

    try:
        response = client.publish(
            TopicArn=topic_arn,
            Subject=subject_line,
            Message=json.dumps(body, default=str),
            MessageAttributes={
                "event_type": {
                    "DataType": "String",
                    "StringValue": event_type,
                }
            },
        )
        logger.info("Evento '%s' publicado a SNS topic %s. MessageId: %s", event_type, topic_arn, response.get("MessageId"))
        return response
    except (BotoCoreError, ClientError) as error:
        logger.warning("Fallo al publicar evento '%s' en SNS (%s): %s", event_type, topic_arn, error)
        return None
