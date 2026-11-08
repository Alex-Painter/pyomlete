"""Recipe photos: a lifelike picture of the dish, made on fal.ai and kept in Mongo.

One call to an image model per photo, no Claude in between: the prompt is
built from the recipe's title and main ingredients, which is enough for a
picture of the dish and costs nothing extra. The model is FLUX.2 [dev] by
default (about $0.012 a photo, a few seconds); `FAL_IMAGE_MODEL` swaps it for
any other fal text-to-image model, such as `fal-ai/flux/krea` or
`fal-ai/imagen4/preview/fast`. See docs/DESIGN.md (Recipe photos) for why.

The bytes are stored in `RecipeImageDocument` and served by
`GET /api/recipe-images/{id}`, because fal's own links don't last. The recipe
keeps a path, not a full URL, so it doesn't depend on which host served it;
the web resolves it against the API (`mediaUrl()` in client/src/lib/api.ts).
"""

import base64
import logging
import os
import time

import httpx
from beanie import PydanticObjectId

from data_models import RecipeDocument, RecipeImageDocument
from lib import analytics
from services.errors import NotConfigured, NotFound, Unavailable
from services.recipes import get as get_recipe

logger = logging.getLogger(__name__)

DEFAULT_MODEL = "fal-ai/flux-2"
# Overridable so a local check can stand in for fal.
FAL_URL = os.environ.get("FAL_RUN_URL") or "https://fal.run"
IMAGE_PATH = "/api/recipe-images/"
# Generous: a model on a cold start can take a while, and the person is
# watching a spinner, not a dead request.
TIMEOUT = httpx.Timeout(90.0, connect=10.0)
MAX_BYTES = 8 * 1024 * 1024


def model() -> str:
    return os.environ.get("FAL_IMAGE_MODEL") or DEFAULT_MODEL


def configured() -> bool:
    return bool(os.environ.get("FAL_KEY"))


def prompt_for(recipe: RecipeDocument) -> str:
    """Describe the finished dish the way a food photographer's brief would."""
    shown = [i.name for i in recipe.ingredients if not i.excluded_from_list][:6]
    with_what = f", made with {', '.join(shown)}" if shown else ""
    cuisine = f" {recipe.cuisine}" if recipe.cuisine else ""
    return (
        f"A realistic, appetising photo of home-cooked{cuisine} {recipe.title}{with_what}, "
        "plated and ready to eat on a simple ceramic plate or bowl on a wooden kitchen table. "
        "Editorial food photography, soft natural window light, 45-degree angle, "
        "shallow depth of field, true-to-life colours and textures. "
        "No text, no labels, no hands, no people."
    )


async def _ask_model(prompt: str) -> tuple[bytes, str]:
    """Ask fal for one photo and return its bytes and content type."""
    body = {
        "prompt": prompt,
        "num_images": 1,
        # Different fal models name the shape differently; each ignores the other.
        "image_size": "landscape_4_3",
        "aspect_ratio": "4:3",
        "output_format": "jpeg",
        "enable_safety_checker": True,
        # Hand the image back in the answer, not as a link to fetch.
        "sync_mode": True,
    }
    headers = {"Authorization": f"Key {os.environ['FAL_KEY']}"}
    async with httpx.AsyncClient(timeout=TIMEOUT) as http:
        res = await http.post(f"{FAL_URL}/{model()}", json=body, headers=headers)
        if res.status_code >= 400:
            raise RuntimeError(f"fal answered {res.status_code}: {res.text[:300]}")
        images = res.json().get("images") or []
        if not images or not images[0].get("url"):
            raise RuntimeError("fal answered with no image")
        url: str = images[0]["url"]
        if url.startswith("data:"):
            header, _, encoded = url.partition(",")
            content_type = header[5:].split(";")[0] or "image/jpeg"
            return base64.b64decode(encoded), content_type
        got = await http.get(url)
        got.raise_for_status()
        return got.content, got.headers.get("content-type", "image/jpeg").split(";")[0]


async def generate(recipe_id: PydanticObjectId, source: str = "web") -> RecipeDocument:
    """Make a new photo for a recipe and make it the recipe's picture."""
    if not configured():
        raise NotConfigured("Photos aren't set up yet: the server has no FAL_KEY.")
    recipe = await get_recipe(recipe_id)
    prompt = prompt_for(recipe)
    started = time.monotonic()
    try:
        data, content_type = await _ask_model(prompt)
        if not content_type.startswith("image/") or not data or len(data) > MAX_BYTES:
            raise RuntimeError(f"fal sent {len(data)} bytes of {content_type}")
    except Exception as exc:
        logger.exception("Making a photo for recipe %s failed", recipe_id)
        analytics.capture(
            "recipe image failed", recipe_id=str(recipe_id), model=model(), source=source,
            error=type(exc).__name__,
        )
        raise Unavailable("Couldn't make a photo just now. Try again in a moment.") from exc
    seconds = round(time.monotonic() - started, 1)
    replaced = recipe.image_url is not None

    image = RecipeImageDocument(
        recipe_id=str(recipe.id), data=data, content_type=content_type, model=model(), prompt=prompt
    )
    await image.insert()
    recipe.image_url = f"{IMAGE_PATH}{image.id}"
    await recipe.save()
    analytics.capture(
        "recipe image generated",
        recipe_id=str(recipe.id),
        model=model(),
        source=source,
        seconds=seconds,
        bytes=len(data),
        replaced=replaced,
    )
    return recipe


async def get_image(image_id: PydanticObjectId) -> RecipeImageDocument:
    image = await RecipeImageDocument.get(image_id)
    if not image:
        raise NotFound("Image not found")
    return image
