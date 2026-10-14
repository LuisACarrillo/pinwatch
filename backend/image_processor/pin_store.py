"""Actualización del registro del pin en RDS.

Pendiente de la tabla pins de Dario. Columnas que el Flujo 2 necesita:
  original_key   llave del original en S3 (única); con ella se encuentra el pin
  status         pending | processed | rejected
  processed_key  llave de la versión comprimida en el bucket processed
  thumbnail_key  llave de la miniatura en el bucket processed

Mientras la tabla no exista, solo se registra en CloudWatch lo que se guardaría.
"""

import json
import logging

logger = logging.getLogger(__name__)


def update_pin_record(
    original_key: str,
    status: str,
    processed_key: str | None = None,
    thumbnail_key: str | None = None,
    reason: str | None = None,
) -> None:
    # Cuando exista la tabla:
    #   UPDATE pins SET status = %s, processed_key = %s, thumbnail_key = %s
    #   WHERE original_key = %s
    # con la conexión de app_secrets.database_settings().
    logger.info(
        json.dumps(
            {
                "event": "pin_pendiente_de_guardar",
                "original_key": original_key,
                "status": status,
                "processed_key": processed_key,
                "thumbnail_key": thumbnail_key,
                "reason": reason,
            },
            ensure_ascii=False,
        )
    )
