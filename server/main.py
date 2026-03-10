from anthropic import AsyncAnthropic, transform_schema
from dotenv import load_dotenv
from fastapi import FastAPI
from pydantic import TypeAdapter
from pymongo.collection import Collection

from lib.db import db, vo
from lib.types import (
    IngredientDB,
    RecipeDB,
    IngredientRecipe,
    RecipeModelResponse,
    RecipePrompt,
)
from tools import find_similar_ingredients

load_dotenv()

async_claude = AsyncAnthropic()


recipeSchema = TypeAdapter(RecipeModelResponse).json_schema()
recipeSchema = transform_schema(recipeSchema)

app = FastAPI()


@app.post("/recipes/generate/")
async def create_recipe(prompt: RecipePrompt):
    system_message = {
        "role": "user",
        "content": "You are a helpful recipe generation assistant. You act as a professional chef helping users turn leftover ingredients into a simple recipe with clear step-by-step instructions. Once you've created a recipe, you must use the find_similar_ingredients tool to match your ingredients with ones from the database, if they exist and have a similarity value over .90. Output the recipe in the given output format.",
    }

    runner = async_claude.beta.messages.tool_runner(
        model="claude-opus-4-5",
        max_tokens=2048,
        messages=[system_message, {"role": "user", "content": prompt.prompt}],
        tools=[find_similar_ingredients],
        stream=True,
        output_config={"format": {"type": "json_schema", "schema": recipeSchema}},
    )

    final_message = await runner.until_done()

    recipe = RecipeModelResponse.model_validate_json(final_message.content[0].text)
    new_ingredients = [i for i in recipe.ingredients if i.is_new]
    new_ingredient_names = [ingredient.name for ingredient in new_ingredients]

    if new_ingredients:
        new_ingredient_vectors = vo.embed(
            texts=new_ingredient_names, model="voyage-4", output_dimension=2048
        ).embeddings

        merged_ingredients = []
        for i, item in enumerate(new_ingredients):
            ing = IngredientDB(
                name=item.name, unit=item.unit, embedding=new_ingredient_vectors[i]
            )
            merged_ingredients.append(ing.model_dump())

        ingredients_col: Collection[IngredientDB] = db["ingredients"]
        ingredients_col.insert_many(merged_ingredients)

    cleaned_ingredients = [
        IngredientRecipe(name=i.name, unit=i.unit, amount=i.amount)
        for i in recipe.ingredients
    ]

    db_recipe = RecipeDB(
        title=recipe.title,
        instructions=recipe.instructions,
        ingredients=cleaned_ingredients,
    )

    recipe_col: Collection[RecipeDB] = db["recipes"]
    recipe_col.insert_one(db_recipe.model_dump())
