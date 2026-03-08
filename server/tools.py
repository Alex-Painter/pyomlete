from anthropic import beta_tool
from pydantic import BaseModel
from pymongo import MongoClient
from dotenv import load_dotenv

import voyageai
import os
import json

load_dotenv()

vo = voyageai.Client()

uri = f"mongodb+srv://{os.environ.get('DB_USER')}:{os.environ.get('DB_PASS')}@cluster0.a9l1yfq.mongodb.net/?appName=Cluster0"
db_client = MongoClient(uri)


class SimilarIngredient(BaseModel):
    name: str
    score: float


class SimilarIngredients(BaseModel):
    dict[str, list[SimilarIngredient]]


@beta_tool
def find_similar_ingredients(ingredient_names: list[str]) -> SimilarIngredients:
    """Search the vector database for existing ingredients. You must use this after you have created a recipe to check if an ingredient you suggested already exists in the database in some semantically similar form.

    Args:
      ingredient_names: a list of suggested ingredients to search for to see if semantically similar ones exist in the DB already
    Returns:
      A dict mapping the original ingredient name to a list of semantically similar ingredients with similarity scores.
    """
    print(ingredient_names)
    # a. Embeds "chopped tomatoes" via your embedding model
    embed_results = vo.embed(
        texts=ingredient_names, model="voyage-4", output_dimension=2048
    )

    # b. Runs Atlas vector search
    db = db_client.get_database("omlete")
    search_result = db.ingredients.aggregate(
        [
            {
                "$vectorSearch": {
                    "exact": False,
                    "index": "vector_index",
                    "numCandidates": 60,
                    "limit": 3,
                    "path": "embedding",
                    "queryVector": embed_results.embeddings[0],
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

    # c. Returns top 3 matches with similarity scores
    search_json = []
    for result in search_result:
        search_json.append(result)

    return json.dumps(search_json)
