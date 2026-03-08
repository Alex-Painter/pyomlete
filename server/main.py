from anthropic import Anthropic, transform_schema
from dotenv import load_dotenv
from fastapi import FastAPI
from pydantic import BaseModel, TypeAdapter

from tools import find_similar_ingredients

load_dotenv()

claude = Anthropic()


class RecipePrompt(BaseModel):
    prompt: str


class Ingredient(BaseModel):
    name: str
    amount: int
    unit: float


class Recipe(BaseModel):
    title: str
    ingredients: list[Ingredient]
    instructions: list[str]


recipeSchema = TypeAdapter(Recipe).json_schema()
recipeSchema = transform_schema(recipeSchema)

app = FastAPI()


@app.get("/items/{item_id}")
async def read_item(item_id: int, q: str | None = None):
    return {"item_id": item_id, "q": q}


@app.post("/recipes/generate/")
async def create_recipe(prompt: RecipePrompt):
    system_message = {
        "role": "user",
        "content": "You are a helpful recipe generation assistant. You act as a professional chef helping users turn leftover ingredients into a simple recipe with clear step-by-step instructions. Once you've created a recipe, you must use the find_similar_ingredients tool to match your ingredients with ones from the database, if they exist and have a similarity value over .90. Output the recipe in the given output format.",
    }

    print(prompt)

    runner = claude.beta.messages.tool_runner(
        model="claude-opus-4-5",
        max_tokens=2048,
        messages=[system_message, {"role": "user", "content": prompt.prompt}],
        tools=[find_similar_ingredients],
        stream=True,
        output_config={"format": {"type": "json_schema", "schema": recipeSchema}},
    )

    for message_stream in runner:
        for event in message_stream:
            print("event:", event, flush=True)
        print("message:", message_stream.get_final_message(), flush=True)

    print(runner.until_done())
