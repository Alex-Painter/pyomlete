import os

from dotenv import load_dotenv
from pymongo import MongoClient, AsyncMongoClient
import voyageai

load_dotenv()

_uri = f"mongodb+srv://{os.environ.get('DB_USER')}:{os.environ.get('DB_PASS')}@cluster0.a9l1yfq.mongodb.net/?appName=Cluster0"
_db_client = MongoClient(_uri)
db = _db_client["omlete"]

_async_db_client = AsyncMongoClient(_uri)
async_db = _async_db_client["omlete"]

vo = voyageai.Client()
