import asyncio
import base64
from contextlib import asynccontextmanager

from anthropic import AsyncAnthropic, transform_schema
from beanie import init_beanie
from dotenv import load_dotenv
from fastapi import FastAPI, UploadFile
from pydantic import TypeAdapter

from data_models import IngredientDocument, RecipeDocument
from lib.db import get_motor_client, vo
from lib.types import IngredientRecipe, RecipeModelResponse, RecipePrompt
from tools import find_similar_ingredients

load_dotenv()

async_claude = AsyncAnthropic()

recipeSchema = TypeAdapter(RecipeModelResponse).json_schema()
recipeSchema = transform_schema(recipeSchema)


@asynccontextmanager
async def lifespan(app: FastAPI):
    client = get_motor_client()
    await init_beanie(
        database=client["omlete"],
        document_models=[IngredientDocument, RecipeDocument],
    )
    yield
    client.close()


app = FastAPI(lifespan=lifespan)


async def _save_recipe(recipe: RecipeModelResponse) -> RecipeDocument:
    new_ingredients = [i for i in recipe.ingredients if i.is_new]
    if new_ingredients:
        vectors = vo.embed(
            texts=[i.name for i in new_ingredients], model="voyage-4", output_dimension=2048
        ).embeddings
        await IngredientDocument.insert_many([
            IngredientDocument(name=item.name, unit=item.unit, embedding=vectors[i])
            for i, item in enumerate(new_ingredients)
        ])

    db_recipe = RecipeDocument(
        title=recipe.title,
        instructions=recipe.instructions,
        ingredients=[
            IngredientRecipe(name=i.name, unit=i.unit, amount=i.amount)
            for i in recipe.ingredients
        ],
    )
    await db_recipe.insert()
    return db_recipe


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
    return await _save_recipe(recipe)


async def _extract_and_save(file: UploadFile) -> RecipeDocument:
    data = base64.standard_b64encode(await file.read()).decode("utf-8")
    runner = async_claude.beta.messages.tool_runner(
        model="claude-opus-4-5",
        max_tokens=2048,
        messages=[{
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {"type": "base64", "media_type": file.content_type, "data": data},
                },
                {
                    "type": "text",
                    "text": "Extract the recipe from this image. Use find_similar_ingredients to match ingredients against the database. Output the recipe in the given JSON format.",
                },
            ],
        }],
        tools=[find_similar_ingredients],
        stream=True,
        output_config={"format": {"type": "json_schema", "schema": recipeSchema}},
    )
    final_message = await runner.until_done()
    recipe = RecipeModelResponse.model_validate_json(final_message.content[0].text)
    return await _save_recipe(recipe)


@app.post("/recipes/extract-from-images/")
async def extract_recipes_from_images(files: list[UploadFile]):
    return await asyncio.gather(*[_extract_and_save(f) for f in files])
