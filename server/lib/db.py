import os

from dotenv import load_dotenv
from motor.motor_asyncio import AsyncIOMotorClient
import voyageai

load_dotenv()

_uri = f"mongodb+srv://{os.environ.get('DB_USER')}:{os.environ.get('DB_PASS')}@cluster0.a9l1yfq.mongodb.net/?appName=Cluster0"


def get_motor_client() -> AsyncIOMotorClient:
    return AsyncIOMotorClient(_uri)


vo = voyageai.Client()
