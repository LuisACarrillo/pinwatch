from io import BytesIO

import pytest
from PIL import Image

from image_processor import processing
from image_processor.processing import InvalidImage, output_keys, process, validate


def make_image(fmt="JPEG", size=(800, 600), mode="RGB", color=(200, 80, 40), **save_options) -> bytes:
    buffer = BytesIO()
    Image.new(mode, size, color).save(buffer, format=fmt, **save_options)
    return buffer.getvalue()


def open_webp(data: bytes) -> Image.Image:
    image = Image.open(BytesIO(data))
    image.load()
    return image


@pytest.mark.parametrize("fmt", ["JPEG", "PNG", "WEBP"])
def test_allowed_formats_pass_validation(fmt):
    assert validate(make_image(fmt)) == fmt


def test_text_with_jpg_extension_is_not_an_image():
    with pytest.raises(InvalidImage) as error:
        validate(b"esto no es una imagen, aunque se llame foto.jpg")
    assert error.value.reason == "not_an_image"


def test_truncated_image_is_rejected():
    data = make_image("PNG")
    with pytest.raises(InvalidImage) as error:
        validate(data[: len(data) // 2])
    assert error.value.reason == "not_an_image"


def test_empty_file_is_rejected():
    with pytest.raises(InvalidImage) as error:
        validate(b"")
    assert error.value.reason == "empty"


def test_gif_is_a_real_image_but_not_allowed():
    with pytest.raises(InvalidImage) as error:
        validate(make_image("GIF", mode="P", color=1))
    assert error.value.reason == "format_not_allowed"


def test_file_over_max_bytes_is_rejected(monkeypatch):
    monkeypatch.setattr(processing, "MAX_BYTES", 1000)
    with pytest.raises(InvalidImage) as error:
        validate(make_image("PNG", size=(300, 300)) + b"\0" * 1000)
    assert error.value.reason == "too_large"


def test_image_over_max_pixels_is_rejected(monkeypatch):
    monkeypatch.setattr(processing, "MAX_PIXELS", 100 * 100)
    with pytest.raises(InvalidImage) as error:
        validate(make_image("PNG", size=(101, 100)))
    assert error.value.reason == "too_many_pixels"


def test_wide_image_is_resized_to_max_widths():
    result = process(make_image("JPEG", size=(3200, 2400)))

    assert (result.source_width, result.source_height) == (3200, 2400)
    assert (result.processed.width, result.processed.height) == (1600, 1200)
    assert (result.thumbnail.width, result.thumbnail.height) == (400, 300)
    for rendition in (result.processed, result.thumbnail):
        image = open_webp(rendition.data)
        assert image.format == "WEBP"
        assert image.size == (rendition.width, rendition.height)


def test_small_image_is_never_upscaled():
    result = process(make_image("PNG", size=(300, 200)))

    assert (result.processed.width, result.processed.height) == (300, 200)
    assert (result.thumbnail.width, result.thumbnail.height) == (300, 200)


def test_png_transparency_is_kept():
    result = process(make_image("PNG", size=(600, 400), mode="RGBA", color=(0, 0, 0, 0)))

    assert open_webp(result.thumbnail.data).mode == "RGBA"


def test_cmyk_jpeg_is_converted_to_rgb():
    result = process(make_image("JPEG", mode="CMYK", color=(0, 100, 200, 0)))

    assert open_webp(result.processed.data).mode == "RGB"


def test_exif_orientation_is_applied_and_metadata_removed():
    exif = Image.Exif()
    exif[0x0112] = 6  # Orientation: rotar 90° (foto de celular en vertical)
    exif[0x010F] = "Fabricante de prueba"  # Make
    data = make_image("JPEG", size=(800, 600), exif=exif.tobytes())

    result = process(data)

    assert (result.processed.width, result.processed.height) == (600, 800)
    assert not open_webp(result.processed.data).getexif()


def test_output_keys_mirror_the_original_key():
    assert output_keys("originals/1234/foto de playa.jpg") == (
        "processed/1234/foto de playa.webp",
        "thumbnails/1234/foto de playa.webp",
    )


def test_output_keys_without_extension():
    assert output_keys("originals/1234/image") == (
        "processed/1234/image.webp",
        "thumbnails/1234/image.webp",
    )


@pytest.mark.parametrize("key", ["processed/1234/foto.webp", "originals/", "originals/../x.jpg"])
def test_output_keys_reject_keys_outside_originals(key):
    with pytest.raises(InvalidImage) as error:
        output_keys(key)
    assert error.value.reason == "bad_key"
