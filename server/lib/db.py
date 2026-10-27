import os

from dotenv import load_dotenv
from motor.motor_asyncio import AsyncIOMotorClient
import voyageai

load_dotenv()

_uri = os.environ.get(
    "DB_URI",
    f"mongodb+srv://{os.environ.get('DB_USER')}:{os.environ.get('DB_PASS')}@cluster0.a9l1yfq.mongodb.net/?appName=Cluster0",
)


def get_motor_client() -> AsyncIOMotorClient:
    return AsyncIOMotorClient(_uri)


async def init_documents(client: AsyncIOMotorClient) -> None:
    """Set up Beanie with every document type, for the API and the weekly run alike."""
    from beanie import init_beanie

    import data_models as d

    await init_beanie(
        database=client["omlete"],
        document_models=[
            d.IngredientDocument,
            d.RecipeDocument,
            d.ListDocument,
            d.UserSettingsDocument,
            d.SuggestionDocument,
            d.RecipeJobDocument,
            d.ChefActionDocument,
            d.MealLogDocument,
            d.PreferenceDocument,
            d.WeekPlanDocument,
            d.CalendarConnectionDocument,
        ],
    )


vo = voyageai.Client()
