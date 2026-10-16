"""Suscriptor del Flujo 2: guarda en pins el resultado que la Lambda de imágenes publica en SNS.

La Lambda de imágenes no entra a la VPC ni toca la base; publica imagen_procesada o
imagen_rechazada en pinwatch-events. Cuando la API corra en Lambda (dentro de la VPC, junto a
la RDS), el tópico la invoca con este evento y main.handler lo manda aquí.
"""

import json
import logging
from typing import Any

import database

logger = logging.getLogger(__name__)

STATUS_BY_EVENT = {"imagen_procesada": "processed", "imagen_rechazada": "rejected"}


class PinNotFoundYet(RuntimeError):
    """El evento llegó antes que el pin: el frontend sube la imagen y después crea el pin.

    Se lanza para que Lambda reintente la invocación asíncrona (dos veces, con minutos de espera).
    """


def is_sns_event(event: Any) -> bool:
    records = event.get("Records") if isinstance(event, dict) else None
    return bool(records) and all(r.get("EventSource") == "aws:sns" for r in records)


def handle_sns_event(event: dict) -> dict[str, Any]:
    results = [apply_message(json.loads(record["Sns"]["Message"])) for record in event["Records"]]
    return {"results": results}


def apply_message(message: dict[str, Any]) -> dict[str, Any]:
    event_type = message.get("event_type")
    status = STATUS_BY_EVENT.get(event_type)
    if status is None:
        # Otros eventos del tópico (pin.liked, ...): la suscripción debería filtrarlos.
        return {"event_type": event_type, "status": "ignored"}

    data = message["data"]
    object_key = data["object_key"]
    with database.get_db() as conn:
        with conn.cursor() as cur:
            if status == "processed":
                cur.execute(
                    "UPDATE pins SET status = %s, processed_key = %s, thumbnail_key = %s WHERE object_key = %s;",
                    (status, data["processed_key"], data["thumbnail_key"], object_key),
                )
            else:
                # Rechazada: no hay archivos en processed/, así que las llaves se vacían.
                cur.execute(
                    "UPDATE pins SET status = %s, processed_key = NULL, thumbnail_key = NULL WHERE object_key = %s;",
                    (status, object_key),
                )
            updated = cur.rowcount

    if updated == 0:
        raise PinNotFoundYet(f"No hay pin con object_key={object_key}; se reintentará.")
    logger.info("Pin(s) con %s marcados como %s.", object_key, status)
    return {"object_key": object_key, "status": status, "updated": updated}
