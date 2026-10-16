"""Punto de entrada de la Lambda: recibe eventos de S3 de originals/ y procesa cada imagen.

Una imagen inválida se registra y se da por terminada: lanzar un error haría que Lambda
reintentara algo que nunca va a pasar. Solo los errores transitorios (S3 o SNS no responden)
se lanzan, y la función tiene un reintento como máximo.
"""

import json
import logging
import os
import time
import urllib.parse

import boto3
from botocore.exceptions import ClientError

from image_processor import events
from image_processor.processing import (
    MAX_BYTES,
    ORIGINALS_PREFIX,
    InvalidImage,
    output_keys,
    process,
)

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_s3 = None


def s3():
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3")
    return _s3


def log(event: str, **fields) -> None:
    logger.info(json.dumps({"event": event, **fields}, ensure_ascii=False))


def handler(event, context):
    # S3 manda un s3:TestEvent sin Records al configurar la notificación.
    results = [process_record(record) for record in event.get("Records", [])]
    return {"results": results}


def process_record(record) -> dict:
    started = time.perf_counter()
    bucket = record["s3"]["bucket"]["name"]
    # S3 entrega la llave codificada como URL (los espacios llegan como +).
    key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
    size = int(record["s3"]["object"].get("size", 0))
    target_bucket = os.environ["PROCESSED_BUCKET"]

    # Defensa contra ciclos: nunca se escribe en el bucket de origen ni se procesa fuera de originals/.
    if target_bucket == bucket:
        log("configuracion_invalida", bucket=bucket, detail="PROCESSED_BUCKET es el bucket de origen.")
        return {"key": key, "status": "ignored"}
    if not key.startswith(ORIGINALS_PREFIX):
        log("imagen_ignorada", bucket=bucket, key=key, detail=f"Fuera de {ORIGINALS_PREFIX}.")
        return {"key": key, "status": "ignored"}

    try:
        if size > MAX_BYTES:
            # Se rechaza con el tamaño del evento, sin descargar el archivo.
            raise InvalidImage("too_large", f"El archivo supera {MAX_BYTES // (1024 * 1024)} MB.")
        processed_key, thumbnail_key = output_keys(key)

        try:
            original = s3().get_object(Bucket=bucket, Key=key)
        except ClientError as error:
            if error.response.get("Error", {}).get("Code") == "NoSuchKey":
                log("original_no_encontrado", bucket=bucket, key=key)
                return {"key": key, "status": "missing"}
            raise
        # Nunca se lee más del límite, aunque el objeto haya crecido.
        data = original["Body"].read(MAX_BYTES + 1)
        result = process(data)
    except InvalidImage as error:
        log("imagen_rechazada", bucket=bucket, key=key, size=size, reason=error.reason, detail=str(error))
        events.publish("imagen_rechazada", key, status="rejected", reason=error.reason)
        return {"key": key, "status": "rejected", "reason": error.reason}

    for target_key, rendition in ((processed_key, result.processed), (thumbnail_key, result.thumbnail)):
        s3().put_object(
            Bucket=target_bucket,
            Key=target_key,
            Body=rendition.data,
            ContentType="image/webp",
            Metadata={"original-key": key},
        )

    log(
        "imagen_procesada",
        bucket=bucket,
        key=key,
        source_format=result.source_format,
        source_size=len(data),
        source_dimensions=f"{result.source_width}x{result.source_height}",
        processed_key=processed_key,
        processed_size=len(result.processed.data),
        thumbnail_key=thumbnail_key,
        thumbnail_size=len(result.thumbnail.data),
        thumbnail_dimensions=f"{result.thumbnail.width}x{result.thumbnail.height}",
        duration_ms=round((time.perf_counter() - started) * 1000),
    )
    events.publish(
        "imagen_procesada", key, status="processed", processed_key=processed_key, thumbnail_key=thumbnail_key
    )
    return {
        "key": key,
        "status": "processed",
        "processed_key": processed_key,
        "thumbnail_key": thumbnail_key,
    }
