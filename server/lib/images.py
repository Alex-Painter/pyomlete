"""Make an uploaded photo one the model can read.

The model reads only JPEG, PNG, GIF and WebP, each up to 5 MB and best at
2000 px or less on its long side. An iPhone's own photos are HEIC, and a
straight-from-camera photo is often bigger than 5 MB, so a recipe photo picked
on the web was refused by the model. Every photo goes through `for_model()`
before a recipe is read from it, so each client can send what its picker gives.
"""

import io
import logging

from PIL import Image, ImageOps, UnidentifiedImageError
from pillow_heif import register_heif_opener

register_heif_opener()

log = logging.getLogger(__name__)

MODEL_TYPES = {"image/jpeg", "image/png", "image/gif", "image/webp"}
MAX_EDGE = 2000
MAX_BYTES = 5 * 1024 * 1024


class NotAnImage(ValueError):
    """The bytes are not a photo this server can open."""


def for_model(media_type: str | None, data: bytes) -> tuple[str, bytes]:
    """The photo as a media type and bytes the model takes.

    A photo already in a type the model reads, small enough and no larger than
    MAX_EDGE passes through untouched. Anything else (HEIC, a missing or wrong
    type, a big camera photo) is opened, turned the way the camera held it,
    shrunk to MAX_EDGE and re-encoded as JPEG.
    """
    try:
        image = Image.open(io.BytesIO(data))
        image.load()
    except (UnidentifiedImageError, OSError) as exc:
        raise NotAnImage(str(exc)) from exc

    if (
        media_type in MODEL_TYPES
        and Image.MIME.get(image.format or "") == media_type
        and len(data) <= MAX_BYTES
        and max(image.size) <= MAX_EDGE
    ):
        return media_type, data

    image = ImageOps.exif_transpose(image)
    image.thumbnail((MAX_EDGE, MAX_EDGE))
    if image.mode != "RGB":
        image = image.convert("RGB")
    out = io.BytesIO()
    image.save(out, format="JPEG", quality=85)
    log.info("photo converted for the model: %s %d bytes -> JPEG %d bytes", media_type, len(data), out.tell())
    return "image/jpeg", out.getvalue()
