"""Llaves de S3 del Flujo 2. Sin dependencias: la API las importa para calcular las mismas llaves
que la Lambda sin cargar Pillow.
"""

from pathlib import PurePosixPath

ORIGINALS_PREFIX = "originals/"
PROCESSED_PREFIX = "processed/"
THUMBNAILS_PREFIX = "thumbnails/"


class InvalidImage(ValueError):
    """El archivo no se procesa. `reason` es un código estable para logs y para la base."""

    def __init__(self, reason: str, message: str) -> None:
        super().__init__(message)
        self.reason = reason


def output_keys(original_key: str) -> tuple[str, str]:
    """originals/<uuid>/foto.jpg -> (processed/<uuid>/foto.webp, thumbnails/<uuid>/foto.webp).

    Las llaves salen solo de la original: si S3 entrega el evento dos veces, se
    sobrescribe el mismo archivo en vez de duplicarlo.
    """
    if not original_key.startswith(ORIGINALS_PREFIX):
        raise InvalidImage("bad_key", f"La llave no está en {ORIGINALS_PREFIX}.")
    relative = PurePosixPath(original_key[len(ORIGINALS_PREFIX) :])
    if not relative.name or ".." in relative.parts:
        raise InvalidImage("bad_key", "La llave no tiene nombre de archivo.")
    target = relative.with_suffix(".webp").as_posix()
    return f"{PROCESSED_PREFIX}{target}", f"{THUMBNAILS_PREFIX}{target}"
