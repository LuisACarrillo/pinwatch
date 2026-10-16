"""Validación y procesamiento de imágenes. No depende de AWS para poder probarse solo."""

from dataclasses import dataclass
from io import BytesIO

from PIL import Image, ImageOps, UnidentifiedImageError

from image_processor.keys import ORIGINALS_PREFIX, InvalidImage, output_keys  # noqa: F401

MAX_BYTES = 15 * 1024 * 1024
# Límite de píxeles contra "bombas de descompresión": archivos chicos que ocupan GB en memoria.
MAX_PIXELS = 40_000_000
ALLOWED_FORMATS = frozenset({"JPEG", "PNG", "WEBP"})

PROCESSED_MAX_WIDTH = 1600
PROCESSED_QUALITY = 80
THUMBNAIL_MAX_WIDTH = 400
THUMBNAIL_QUALITY = 75


@dataclass(frozen=True)
class Rendition:
    data: bytes
    width: int
    height: int


@dataclass(frozen=True)
class ProcessedImage:
    source_format: str
    source_width: int
    source_height: int
    processed: Rendition
    thumbnail: Rendition


def validate(data: bytes) -> str:
    """Revisa el contenido real del archivo (no la extensión) y devuelve su formato."""
    if not data:
        raise InvalidImage("empty", "El archivo está vacío.")
    if len(data) > MAX_BYTES:
        raise InvalidImage("too_large", f"El archivo supera {MAX_BYTES // (1024 * 1024)} MB.")

    try:
        with Image.open(BytesIO(data)) as image:
            image_format = image.format
            width, height = image.size
            image.verify()
    except Image.DecompressionBombError as error:
        raise InvalidImage("too_many_pixels", "La imagen tiene demasiados píxeles.") from error
    except (UnidentifiedImageError, OSError, SyntaxError, ValueError) as error:
        raise InvalidImage("not_an_image", "El archivo no es una imagen válida.") from error

    if image_format not in ALLOWED_FORMATS:
        raise InvalidImage("format_not_allowed", f"Formato no permitido: {image_format}.")
    if width * height > MAX_PIXELS:
        raise InvalidImage("too_many_pixels", "La imagen tiene demasiados píxeles.")
    return image_format


def process(data: bytes) -> ProcessedImage:
    """Valida y genera la versión comprimida y la miniatura, ambas en WebP."""
    image_format = validate(data)

    # verify() deja el archivo inutilizable; se abre de nuevo para trabajar con él.
    with Image.open(BytesIO(data)) as source:
        source_width, source_height = source.size
        # Endereza según la orientación EXIF; al guardar, el EXIF (con GPS y cámara) no se copia.
        image = ImageOps.exif_transpose(source)
        icc_profile = source.info.get("icc_profile")
        image = _normalize_mode(image)
        processed = _render(image, PROCESSED_MAX_WIDTH, PROCESSED_QUALITY, icc_profile)
        thumbnail = _render(image, THUMBNAIL_MAX_WIDTH, THUMBNAIL_QUALITY, icc_profile)

    return ProcessedImage(image_format, source_width, source_height, processed, thumbnail)


def _normalize_mode(image: Image.Image) -> Image.Image:
    has_alpha = image.mode in ("RGBA", "LA", "PA") or (
        image.mode == "P" and "transparency" in image.info
    )
    target = "RGBA" if has_alpha else "RGB"
    return image if image.mode == target else image.convert(target)


def _render(image: Image.Image, max_width: int, quality: int, icc_profile: bytes | None) -> Rendition:
    # Nunca se agranda: una imagen angosta se queda en su ancho.
    if image.width > max_width:
        height = max(1, round(image.height * max_width / image.width))
        image = image.resize((max_width, height), Image.Resampling.LANCZOS)

    buffer = BytesIO()
    options = {"format": "WEBP", "quality": quality}
    if icc_profile:
        options["icc_profile"] = icc_profile
    image.save(buffer, **options)
    return Rendition(buffer.getvalue(), image.width, image.height)
