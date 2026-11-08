"""Photos are made into ones the model reads: iPhone HEIC, big camera photos, missing types."""

import io

import pytest
from PIL import Image

from lib.images import MAX_EDGE, NotAnImage, for_model
from tests.photos import MIME, photo


def opened(data: bytes) -> Image.Image:
    return Image.open(io.BytesIO(data))


@pytest.mark.parametrize("fmt", ["JPEG", "PNG", "GIF", "WEBP"])
def test_a_small_photo_the_model_reads_passes_through_untouched(fmt):
    data = photo(fmt)
    assert for_model(MIME[fmt], data) == (MIME[fmt], data)


@pytest.mark.parametrize("media_type", ["image/heic", "image/heif", "", None, "application/octet-stream"])
def test_an_iphone_heic_photo_becomes_a_jpeg(media_type):
    media, data = for_model(media_type, photo("HEIF", size=(40, 30)))
    assert media == "image/jpeg"
    assert opened(data).format == "JPEG"
    assert opened(data).size == (40, 30)


def test_a_photo_that_says_the_wrong_type_is_re_encoded():
    media, data = for_model("image/png", photo("JPEG"))
    assert (media, opened(data).format) == ("image/jpeg", "JPEG")


def test_a_big_camera_photo_is_shrunk_to_the_long_edge():
    media, data = for_model("image/jpeg", photo(size=(4032, 3024)))
    assert media == "image/jpeg"
    assert opened(data).size == (MAX_EDGE, 1500)


def test_a_sideways_camera_photo_is_turned_the_way_it_was_held():
    exif = Image.Exif()
    exif[0x0112] = 6  # rotate 90° clockwise to display
    _, data = for_model("image/heic", photo("HEIF", size=(40, 30), exif=exif.tobytes()))
    assert opened(data).size == (30, 40)


@pytest.mark.parametrize("data", [b"", b"not a photo"])
def test_bytes_that_are_not_a_photo_are_refused(data):
    with pytest.raises(NotAnImage):
        for_model("image/jpeg", data)
