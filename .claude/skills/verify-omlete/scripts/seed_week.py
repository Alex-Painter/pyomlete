"""Insert a tagged meal library for driving Plan's ranking (fit score, Top three).

Usage: seed_week.py <mongo-uri> [--many N] [--clear]

Inserts the "Week Fixture" recipes below with their tags, as Haiku would
have tagged them, plus an old week list so Shepherd's pie was last had in
August. --many N adds N filler recipes with varied tags, for timing the
ranking over a big library. Idempotent: earlier fixtures and their old week
are removed first. --clear removes them and inserts nothing.
"""

import json
import random
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

from pymongo import MongoClient

PREFIX = "Week Fixture"
OLD_WEEK = "2026-08-01"
API = "http://127.0.0.1:8000/api"

FP, MF, DE, PD = "Fresh Produce", "Meat & Fish", "Dairy & Eggs", "Pantry & Dry Goods"

# title, base, main, mood, cuisine, minutes, rating, ingredients
LIBRARY = [
    ("Spaghetti carbonara", "pasta", "pork", "comforting", "italian", 25, 5,
     [("spaghetti", PD), ("bacon", MF), ("eggs", DE), ("parmesan", DE)]),
    ("Pesto pasta", "pasta", "veggie", "fresh", "italian", 15, 4,
     [("pasta", PD), ("basil", FP), ("parmesan", DE), ("pine nuts", PD)]),
    ("Creamy spinach pasta", "pasta", "veggie", "comforting", "italian", 20, 3,
     [("pasta", PD), ("spinach", FP), ("cream", DE)]),
    ("Lasagne", "pasta", "beef", "comforting", "italian", 90, 5,
     [("lasagne sheets", PD), ("beef mince", MF), ("milk", DE)]),
    ("Chicken tikka masala", "rice", "chicken", "comforting", "indian", 45, 5,
     [("chicken thighs", MF), ("rice", PD), ("yoghurt", DE), ("coriander", FP)]),
    ("Thai green curry", "rice", "chicken", "fresh", "south_east_asian", 30, 4,
     [("chicken thighs", MF), ("coconut milk", PD), ("coriander", FP), ("lime", FP)]),
    ("Pho", "noodles", "beef", "fresh", "south_east_asian", 40, 4,
     [("rice noodles", PD), ("beef steak", MF), ("coriander", FP), ("lime", FP)]),
    ("Vietnamese noodle salad", "noodles", "veggie", "fresh", "south_east_asian", 20, None,
     [("rice noodles", PD), ("coriander", FP), ("lime", FP), ("carrot", FP)]),
    ("Fish pie", "potatoes", "fish", "comforting", "british", 60, 4,
     [("potatoes", FP), ("smoked haddock", MF), ("milk", DE)]),
    ("Spinach and feta frittata", "none", "veggie", "fresh", "greek", 20, 4,
     [("eggs", DE), ("spinach", FP), ("feta", DE)]),
    ("Spanakopita", "bread", "veggie", "comforting", "greek", 50, 5,
     [("filo pastry", PD), ("spinach", FP), ("feta", DE)]),
    ("Saag aloo", "potatoes", "veggie", "comforting", "indian", 35, None,
     [("potatoes", FP), ("spinach", FP), ("garam masala", PD)]),
    ("Chicken traybake", "potatoes", "chicken", "comforting", "british", 50, 4,
     [("chicken thighs", MF), ("potatoes", FP), ("lemon", FP)]),
    ("Beef tacos", "bread", "beef", "different", "mexican", 25, 3,
     [("tortillas", PD), ("beef mince", MF), ("lime", FP)]),
    ("Lentil soup", "none", "beans", "comforting", "middle_eastern", 40, 4,
     [("red lentils", PD), ("carrot", FP), ("cumin", PD)]),
    ("Salmon teriyaki", "rice", "fish", "fresh", "japanese", 25, 5,
     [("salmon", MF), ("rice", PD), ("soy sauce", PD), ("spring onions", FP)]),
    ("Shepherd's pie", "potatoes", "lamb", "comforting", "british", 75, 5,
     [("lamb mince", MF), ("potatoes", FP), ("carrot", FP)]),
    ("Bean chilli", "rice", "beans", "comforting", "mexican", 45, 2,
     [("kidney beans", PD), ("rice", PD), ("peppers", FP)]),
    ("Mushroom risotto", "rice", "veggie", "comforting", "italian", 40, 4,
     [("risotto rice", PD), ("mushrooms", FP), ("parmesan", DE)]),
    ("Halloumi wraps", "bread", "veggie", "fresh", "middle_eastern", 15, 4,
     [("halloumi", DE), ("tortillas", PD), ("peppers", FP)]),
    ("Pad thai", "noodles", "chicken", "different", "south_east_asian", 25, None,
     [("rice noodles", PD), ("chicken breast", MF), ("lime", FP), ("coriander", FP)]),
    ("Tofu stir fry", "noodles", "beans", "fresh", "chinese", 20, 3,
     [("tofu", FP), ("egg noodles", PD), ("pak choi", FP)]),
    ("Mystery stew", None, None, None, None, 60, 5,
     [("stewing beef", MF), ("carrot", FP)]),
    ("Sausage and mash", "potatoes", "pork", "comforting", "british", 35, 4,
     [("sausages", MF), ("potatoes", FP), ("onion", FP)]),
]

BASES = ["rice", "pasta", "potatoes", "bread", "noodles", "none"]
MAINS = ["chicken", "beef", "pork", "lamb", "fish", "veggie", "beans"]
MOODS = ["comforting", "fresh", "different"]
CUISINES = ["british", "italian", "indian", "south_east_asian", "mexican", "greek", "japanese"]
FOODS = [("spinach", FP), ("onion", FP), ("garlic", FP), ("feta", DE), ("chicken thighs", MF), ("rice", PD)]


def ing(name, category):
    return {
        "name": name, "unit": "g", "amount": 100, "note": None, "group": None,
        "category": category, "excluded_from_list": False,
    }


def tags(base, main, mood, cuisine):
    if base is None:
        return None
    return {
        "base": base, "main": main, "mood": mood, "cuisine": cuisine,
        "traits": {
            "oily_fish": main == "fish", "red_meat": main in ("beef", "lamb", "pork"),
            "veg_led": main == "veggie", "legumes": main == "beans",
        },
    }


def recipes(many: int):
    now = datetime.now(timezone.utc)
    docs = [
        {
            "title": title,
            "instructions": ["Cook it."],
            "ingredients": [ing(n, c) for n, c in ingredients],
            "rating": rating,
            "total_minutes": minutes,
            "tags": tags(base, main, mood, cuisine),
            "source_name": PREFIX,
            "created_at": now - timedelta(days=i),
        }
        for i, (title, base, main, mood, cuisine, minutes, rating, ingredients) in enumerate(LIBRARY)
    ]
    rnd = random.Random(7)
    for i in range(many):
        docs.append({
            "title": f"Filler dish {i + 1}",
            "instructions": ["Cook it."],
            "ingredients": [ing(n, c) for n, c in rnd.sample(FOODS, 3)],
            "rating": rnd.choice([None, 2, 3, 4, 5]),
            "total_minutes": rnd.randrange(10, 90, 5),
            "tags": tags(rnd.choice(BASES), rnd.choice(MAINS), rnd.choice(MOODS), rnd.choice(CUISINES)),
            "source_name": PREFIX,
            "created_at": now - timedelta(days=100 + i),
        })
    return docs


def api(method: str, path: str, body: dict) -> dict:
    req = urllib.request.Request(
        f"{API}{path}", method=method, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as res:
        return json.load(res)


def main() -> None:
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    db = MongoClient(args[0])["omlete"]
    many = int(args[args.index("--many") + 1]) if "--many" in args else 0

    db.recipes.delete_many({"source_name": PREFIX})
    db.lists.delete_many({"name": f"{PREFIX} old week"})
    if "--clear" in args:
        print("cleared week fixtures")
        return

    ids = db.recipes.insert_many(recipes(many)).inserted_ids
    # The old week goes through the API, so it's stored exactly as the app stores weeks.
    shepherds = str(ids[[r[0] for r in LIBRARY].index("Shepherd's pie")])
    week = api("POST", "/lists/", {"week_start": OLD_WEEK})
    api("PATCH", f"/lists/{week['id']}", {"name": f"{PREFIX} old week"})
    api("PUT", f"/lists/{week['id']}/days/2026-08-03", {"recipe_id": shepherds})
    print(f"seeded {len(ids)} week fixture recipes")


if __name__ == "__main__":
    main()
