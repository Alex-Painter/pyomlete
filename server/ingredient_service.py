import asyncio

import voyageai

from data_models import IngredientDocument
from lib.types import Match, QueryMatch

_SIMILARITY_THRESHOLD = 0.9
_VOYAGE_MODEL = "voyage-4"
_VOYAGE_OUTPUT_DIMENSION = 2048


class IngredientService:
    def __init__(self) -> None:
        self._vo = voyageai.Client()

    async def find_similar(self, ingredient_names: list[str]) -> list[QueryMatch]:
        if not ingredient_names:
            return []

        embed_results = self._vo.embed(
            texts=ingredient_names,
            model=_VOYAGE_MODEL,
            output_dimension=_VOYAGE_OUTPUT_DIMENSION,
        )

        search_results = await asyncio.gather(
            *[self._search_by_embedding(e) for e in embed_results.embeddings]
        )

        return [
            QueryMatch(
                query=ingredient_names[i],
                matches=[
                    Match(name=doc["name"], score=doc["score"], unit=doc["unit"])
                    for doc in results
                    if doc.get("score", 0) >= _SIMILARITY_THRESHOLD
                ],
            )
            for i, results in enumerate(search_results)
        ]

    async def _search_by_embedding(self, embedding: list[float]) -> list[dict]:
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
