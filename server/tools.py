import json
import asyncio

from anthropic import beta_async_tool
from dotenv import load_dotenv

from lib.db import async_db, vo
from lib.types import SimilarIngredients

load_dotenv()


@beta_async_tool
async def find_similar_ingredients(ingredient_names: list[str]) -> SimilarIngredients:
    """Search the vector database for existing ingredients. You must use this after you have created a recipe to check if an ingredient you suggested already exists in the database in some semantically similar form.

    Args:
      ingredient_names: a list of suggested ingredients to search for to see if semantically similar ones exist in the DB already
    Returns:
      A dict mapping the original ingredient name to a list of semantically similar ingredients with similarity scores.
    """
    # a. Embeds "chopped tomatoes" via your embedding model
    embed_results = vo.embed(
        texts=ingredient_names, model="voyage-4", output_dimension=2048
    )

    # b. Runs Atlas vector search
    vector_searches = await asyncio.gather(
        *[_generate_vector_searches(e) for e in embed_results.embeddings]
    )

    async def collect_cursor(cursor):
        return [doc async for doc in cursor]

    search_results = await asyncio.gather(*[collect_cursor(c) for c in vector_searches])

    # c. Returns top 3 matches with similarity scores
    r = [
        {
            "query": ingredient_names[i],
            "matches": [doc for doc in results if doc["score"] >= 0.9],
        }
        for i, results in enumerate(search_results)
    ]

    return json.dumps(r)


def _generate_vector_searches(embedding: list[float]):
    return async_db.ingredients.aggregate(
        [
            {
                "$vectorSearch": {
                    "exact": False,
                    "index": "vector_index",
                    "numCandidates": 60,
                    "limit": 3,
                    "path": "embedding",
                    "queryVector": embedding,
                }
            },
            {
                "$project": {
                    "_id": 0,
                    "embedding": 0,
                    "aliases": 0,
                    "category": 0,
                    "score": {"$meta": "vectorSearchScore"},
                }
            },
        ]
    )
