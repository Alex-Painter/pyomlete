"""Insert known fixture recipes into the local verify database.

Usage: seed.py <mongo-uri> [--clear]

Idempotent: removes any earlier "Verify Fixture" recipes first, so a re-run
leaves exactly the fixtures below. --clear removes them and inserts nothing.
Writes straight to Mongo because every API route that creates a recipe goes
through Claude, and the fixtures must exist without an API key.

Also caches a category for the ingredient names in CACHED_INGREDIENTS, so
adding them to a list (POST /api/categorize) is answered from Mongo instead of
Claude. The embedding is a zero vector: fine for the cache lookup, useless for
$vectorSearch.
"""

import sys
from datetime import datetime, timedelta, timezone

from pymongo import MongoClient

PREFIX = "Verify Fixture"
CACHED_INGREDIENTS = {"milk": "Dairy & Eggs", "bananas": "Fresh Produce"}


def ing(name, unit, amount, category, note=None):
    return {
        "name": name, "unit": unit, "amount": amount, "note": note, "group": None,
        "category": category, "excluded_from_list": False,
    }


def fixtures():
    now = datetime.now(timezone.utc)
    return [
        {
            "title": f"{PREFIX} Shakshuka",
            "instructions": [
                "Soften the onion and pepper in olive oil.",
                "Add tomatoes and spices; simmer 10 minutes.",
                "Make wells, crack in the eggs, cover until set.",
            ],
            "ingredients": [
                ing("eggs", "whole", 4, "Dairy & Eggs"),
                ing("chopped tomatoes", "grams", 400, "Pantry & Dry Goods"),
                ing("onion", "whole", 1, "Fresh Produce", note="finely chopped"),
                ing("red pepper", "whole", 1, "Fresh Produce"),
            ],
            "rating": 4,
            "servings": 2,
            "total_minutes": 25,
            "created_at": now,
        },
        {
            "title": f"{PREFIX} Lemon Drizzle Cake",
            "instructions": [
                "Cream butter and sugar, beat in eggs.",
                "Fold in flour and lemon zest; bake 45 minutes at 180C.",
                "Pour lemon syrup over the warm cake.",
            ],
            "ingredients": [
                ing("butter", "grams", 225, "Dairy & Eggs"),
                ing("caster sugar", "grams", 225, "Pantry & Dry Goods"),
                ing("self-raising flour", "grams", 275, "Pantry & Dry Goods"),
                ing("lemon", "whole", 2, "Fresh Produce", note="zested"),
            ],
            "rating": None,
            "created_at": now - timedelta(minutes=1),
        },
    ]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    uri, clear = sys.argv[1], "--clear" in sys.argv[2:]
    db = MongoClient(uri, serverSelectionTimeoutMS=5000)["omlete"]
    removed = db.recipes.delete_many({"title": {"$regex": f"^{PREFIX} "}}).deleted_count
    removed += db.ingredients.delete_many({"verify_fixture": True}).deleted_count
    print(f"removed {removed} earlier fixture document(s)")
    if clear:
        return
    for name, category in CACHED_INGREDIENTS.items():
        db.ingredients.insert_one({
            "name": name, "unit": "whole", "category": category,
            "embedding": [0.0] * 2048, "verify_fixture": True,
        })
    print(f"cached categories for: {', '.join(CACHED_INGREDIENTS)}")
    for doc in fixtures():
        rid = db.recipes.insert_one(doc).inserted_id
        print(f"{rid}  {doc['title']}")


if __name__ == "__main__":
    main()
