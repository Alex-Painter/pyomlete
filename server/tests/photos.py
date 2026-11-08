"""Small real photos for tests: the server opens every photo it is sent."""

import io

from PIL import Image
from pillow_heif import register_heif_opener

register_heif_opener()

MIME = {"JPEG": "image/jpeg", "PNG": "image/png", "GIF": "image/gif", "WEBP": "image/webp", "HEIF": "image/heic"}


def photo(fmt: str = "JPEG", size: tuple[int, int] = (8, 8), colour: str = "white", exif: bytes | None = None) -> bytes:
    out = io.BytesIO()
    extra = {"exif": exif} if exif else {}
    Image.new("RGB", size, colour).save(out, format=fmt, **extra)
    return out.getvalue()


PAGE = photo()
