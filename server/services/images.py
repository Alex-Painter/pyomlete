"""Recipe photos: a lifelike picture of the dish, made on fal.ai and kept in Mongo.

One call to an image model per photo, no Claude in between: the prompt is
built from the recipe's title, description and method, so the model draws the
cooked, plated dish rather than its raw ingredients, and costs nothing extra. The model is FLUX.2 [dev] by
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


# How much of the method goes into the prompt. FLUX.2 reads long prompts, but
# past a few hundred words the dish and its look get diluted, so the method is
# kept short and goes last.
METHOD_BUDGET = 700
STEP_LIMIT = 220
# A method shorter than this ("Cook it.") says nothing about how the dish
# looks, so the main ingredients stand in for it.
THIN_METHOD = 80


def _shorten(text: str, limit: int) -> str:
    text = " ".join(text.split())
    if len(text) <= limit:
        return text
    return text[:limit].rsplit(" ", 1)[0].rstrip(",;:") + "…"


def _method_for(recipe: RecipeDocument) -> str:
    """The method, shortened to fit, keeping the last steps when it must cut.

    The last steps say how the dish is finished and served, which is what the
    photo shows, so they're the ones kept.
    """
    kept: list[str] = []
    used = 0
    for step in reversed([s for s in recipe.instructions if s.strip()]):
        step = _shorten(step, STEP_LIMIT)
        if kept and used + len(step) > METHOD_BUDGET:
            break
        kept.insert(0, step)
        used += len(step) + 1
    return " ".join(kept)


def prompt_for(recipe: RecipeDocument) -> str:
    """Describe the finished dish the way a food photographer's brief would.

    An image model takes a list of ingredients literally: given "butter,
    garlic, shallots, curry powder" it scatters a pat of butter, whole cloves
    and a pile of spice on the plate. So the prompt describes the cooked
    result: the title, the recipe's own description and the method, which says
    what each ingredient becomes. Ingredients are named only when the method is
    too thin to say what the dish is.

    Following Black Forest Labs' FLUX.2 guide: the dish comes first, because
    earlier words weigh more; the look comes next and the method last, as
    supporting detail; a named camera, lens and aperture rather than
    "professional photo"; real textures and small imperfections for realism;
    and every instruction is positive, because FLUX.2 has no negative prompt
    and "no garlic" draws its attention to garlic. See docs/DESIGN.md (Recipe
    photos).
    """
    cuisine = f" {recipe.cuisine}" if recipe.cuisine else ""
    parts = [
        f"Food photography of {recipe.title}, a finished home-cooked{cuisine} dish, "
        "plated and ready to eat."
    ]
    if recipe.description:
        parts.append(_shorten(recipe.description, 300))
    parts.append(
        "Everything on the plate is cooked and finished as the recipe serves it: sauces "
        "smooth and glossy, spooned over or pooled beneath, spices and aromatics cooked "
        "into the food, butter melted into the sauce, herbs freshly chopped. The plate "
        "holds only the finished food with a clean rim, a simple ceramic plate or bowl "
        "on a wooden kitchen table beside a folded linen napkin."
    )
    parts.append(
        "Shot on a Sony A7 IV with a 90mm macro lens at f/2.8, 45-degree angle, soft "
        "natural window light from the side, sharp focus on the food and a softly "
        "blurred background. Real textures: browned and crisp edges, glossy sauce, "
        "crumbs, drips and small imperfections, a generous home portion, true-to-life "
        "colours. Natural and unstyled, like a real photo taken at the table."
    )
    method = _method_for(recipe)
    if len(method) >= THIN_METHOD:
        parts.append(f"How it was cooked: {method}")
    else:
        shown = [i.name for i in recipe.ingredients if not i.excluded_from_list][:6]
        if shown:
            parts.append(f"It is cooked with {', '.join(shown)}, all cooked into the dish.")
    return " ".join(parts)


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
