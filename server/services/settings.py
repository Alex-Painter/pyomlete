"""The household's aisle order, and which aisle an item belongs in."""

import re

from data_models import CategoryConfig, IngredientDocument, UserSettingsDocument
from lib.claude import async_claude


async def get_or_create() -> UserSettingsDocument:
    settings = await UserSettingsDocument.find_one()
    if not settings:
        settings = UserSettingsDocument()
        await settings.insert()
    return settings


async def category_names() -> list[str]:
    settings = await get_or_create()
    return [c.name for c in sorted(settings.categories, key=lambda c: c.order)]


async def set_categories(categories: list[CategoryConfig]) -> list[CategoryConfig]:
    settings = await get_or_create()
    settings.categories = categories
    await settings.save()
    return settings.categories


async def categorize(name: str) -> str:
    """The aisle for a shopping item, from the ingredient cache or Haiku."""
    # 1. Check IngredientDocument cache (case-insensitive)
    escaped_name = re.escape(name)
    cached = await IngredientDocument.find_one(
        {"name": {"$regex": f"^{escaped_name}$", "$options": "i"}}
    )
    if cached and cached.category:
        return cached.category

    # 2. Fall back to Claude Haiku
    names = await category_names()
    categories_str = ", ".join(names)

    response = await async_claude.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=50,
        messages=[{
            "role": "user",
            "content": f"Categorize this shopping item into exactly one of these categories: [{categories_str}]. Item: \"{name}\". Reply with just the category name, nothing else.",
        }],
    )
    category = response.content[0].text.strip()

    # Validate against user's categories, fall back to "Other"
    if category not in names:
        category = "Other"

    # 3. Persist to IngredientDocument cache if it already exists
    # (New ingredients without embeddings are only created during recipe import)
    if cached:
        cached.category = category
        await cached.save()

    return category
