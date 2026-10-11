"""Shopping lists and what is on them.

Shared by the routes and by Chef's tools. Errors are typed HTTPExceptions, as
in services.recipes.
"""

from datetime import datetime, timezone

from beanie import PydanticObjectId
from beanie.operators import In

from data_models import ItemSource, ListDocument, ListItem, RecipeDocument
from lib.types import ItemUpdateRequest
from services import recipes
from services.errors import Invalid, NotFound


def _ordinal(n: int) -> str:
    if 11 <= n % 100 <= 13:
        suffix = "th"
    else:
        suffix = {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def _auto_list_name() -> str:
    now = datetime.now(timezone.utc)
    return f"{_ordinal(now.day)} {now.strftime('%B')}"


async def get(list_id: PydanticObjectId) -> ListDocument:
    lst = await ListDocument.get(list_id)
    if not lst:
        raise NotFound("List not found")
    return lst


async def summaries() -> list[dict]:
    """Every list, newest first, with counts and the meals on it."""
    lists = await ListDocument.find_all().sort("-created_at").to_list()
    results = []
    for lst in lists:
        recipes_summary = []
        if lst.recipes:
            oids = [PydanticObjectId(rid) for rid in lst.recipes]
            found = await RecipeDocument.find(In(RecipeDocument.id, oids)).to_list()
            recipes_summary = [{"id": str(r.id), "title": r.title} for r in found]
        results.append({
            "id": str(lst.id),
            "name": lst.name,
            "created_at": lst.created_at.isoformat() if lst.created_at else None,
            "item_count": len(lst.items),
            "checked_count": sum(1 for item in lst.items if item.checked),
            "recipes": recipes_summary,
        })
    return results


async def create() -> ListDocument:
    lst = ListDocument(name=_auto_list_name())
    await lst.insert()
    return lst


async def rename(list_id: PydanticObjectId, name: str | None) -> ListDocument:
    lst = await get(list_id)
    if name is not None:
        lst.name = name
    await lst.save()
    return lst


async def delete(list_id: PydanticObjectId) -> None:
    await (await get(list_id)).delete()


async def duplicate(list_id: PydanticObjectId) -> ListDocument:
    """A fresh copy of a list, everything unticked, named for today."""
    lst = await get(list_id)
    new_items = [
        ListItem(
            name=item.name,
            amount=item.amount,
            unit=item.unit,
            category=item.category,
            checked=False,
            sources=item.sources,
        )
        for item in lst.items
    ]
    new_lst = ListDocument(
        name=_auto_list_name(),
        recipes=list(lst.recipes),
        items=new_items,
    )
    await new_lst.insert()
    return new_lst


def total_amount(sources: list[ItemSource]) -> float | None:
    """Sum the quantified sources, ignoring the ones with no amount.

    An item can be contributed by one recipe that says "200g" and another that
    just says "olive oil". The honest total is 200g — not 200 plus an invented
    zero — and an item nothing quantifies stays unquantified.
    """
    amounts = [s.amount for s in sources if s.amount is not None]
    if not amounts:
        return None
    return round(sum(amounts), 2)


async def put_recipe(lst: ListDocument, recipe: RecipeDocument) -> None:
    """Put a recipe's ingredients on a list and save it."""
    recipe_id = str(recipe.id)
    lst.recipes.append(recipe_id)

    # Merge recipe ingredients into list items (skip excluded)
    for ing in recipe.ingredients:
        if ing.excluded_from_list:
            continue
        source = ItemSource(recipe_id=recipe_id, amount=ing.amount)
        # Find existing item with same name + unit (case-insensitive name, exact unit)
        matched = None
        for item in lst.items:
            if item.name.lower() == ing.name.lower() and item.unit == ing.unit:
                matched = item
                break

        if matched:
            matched.sources.append(source)
            matched.amount = total_amount(matched.sources)
        else:
            lst.items.append(ListItem(
                name=ing.name,
                amount=ing.amount,
                unit=ing.unit,
                category=ing.category,
                sources=[source],
            ))

    await lst.save()


async def add_recipe(list_id: PydanticObjectId, recipe_id: str) -> ListDocument:
    lst = await get(list_id)
    recipe = await recipes.get(PydanticObjectId(recipe_id))
    # Avoid adding the same recipe twice
    if recipe_id in lst.recipes:
        raise Invalid("Recipe already on this list")
    await put_recipe(lst, recipe)
    return lst


async def remove_recipe(list_id: PydanticObjectId, recipe_id: str) -> ListDocument:
    """Take a meal off a list, and the items only it put there."""
    lst = await get(list_id)
    if recipe_id not in lst.recipes:
        raise NotFound("Recipe not on this list")

    lst.recipes.remove(recipe_id)

    # Subtract recipe's contributions from items
    remaining_items = []
    for item in lst.items:
        item.sources = [s for s in item.sources if s.recipe_id != recipe_id]
        if item.sources:
            item.amount = total_amount(item.sources)
            remaining_items.append(item)
        # Items with no remaining sources are dropped
    lst.items = remaining_items

    await lst.save()
    return lst


async def add_item(
    list_id: PydanticObjectId,
    name: str,
    amount: float | None = None,
    unit: str | None = None,
    category: str = "Other",
    item_id: str | None = None,
) -> ListItem:
    lst = await get(list_id)
    if item_id:
        existing = next((i for i in lst.items if i.id == item_id), None)
        if existing:
            # A retried offline add. It already landed; don't add it twice.
            return existing
    item = ListItem(
        name=name,
        amount=amount,
        unit=unit,
        category=category,
        sources=[ItemSource(recipe_id=None, amount=amount)],
        **({"id": item_id} if item_id else {}),
    )
    lst.items.append(item)
    await lst.save()
    return item


async def reorder_items(
    list_id: PydanticObjectId, category: str, item_ids: list[str]
) -> ListDocument:
    lst = await get(list_id)

    by_id = {item.id: item for item in lst.items}
    # Only reorder items that exist and belong to the given category.
    ordered = [
        by_id[item_id]
        for item_id in item_ids
        if item_id in by_id and by_id[item_id].category == category
    ]
    # The slots currently occupied by the reordered items stay put; we just
    # rewrite them in the new order, leaving everything else in place.
    reordered_ids = {item.id for item in ordered}
    slots = [idx for idx, item in enumerate(lst.items) if item.id in reordered_ids]
    for slot, item in zip(slots, ordered):
        lst.items[slot] = item

    await lst.save()
    return lst


async def update_item(
    list_id: PydanticObjectId, item_id: str, changes: ItemUpdateRequest
) -> ListItem:
    lst = await get(list_id)
    for item in lst.items:
        if item.id == item_id:
            if changes.name is not None:
                item.name = changes.name
            # amount and unit can be cleared, so an explicit null counts.
            if "amount" in changes.model_fields_set:
                item.amount = changes.amount
            if "unit" in changes.model_fields_set:
                item.unit = changes.unit
            if changes.category is not None:
                item.category = changes.category
            if changes.checked is not None:
                item.checked = changes.checked
            await lst.save()
            return item
    raise NotFound("Item not found")


async def delete_item(list_id: PydanticObjectId, item_id: str) -> None:
    lst = await get(list_id)
    original_len = len(lst.items)
    lst.items = [item for item in lst.items if item.id != item_id]
    if len(lst.items) == original_len:
        raise NotFound("Item not found")
    await lst.save()
