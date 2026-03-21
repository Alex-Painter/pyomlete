import json
import asyncio

from anthropic import beta_async_tool
from dotenv import load_dotenv

from data_models import IngredientDocument
from lib.db import vo
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
    embed_results = vo.embed(
        texts=ingredient_names, model="voyage-4", output_dimension=2048
    )

    search_results = await asyncio.gather(
        *[_search_by_embedding(e) for e in embed_results.embeddings]
    )

    r = [
        {
            "query": ingredient_names[i],
            "matches": [doc for doc in results if doc["score"] >= 0.9],
        }
        for i, results in enumerate(search_results)
    ]

    return json.dumps(r)


async def _search_by_embedding(embedding: list[float]) -> list[dict]:
    return await IngredientDocument.aggregate(
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
    ).to_list()
