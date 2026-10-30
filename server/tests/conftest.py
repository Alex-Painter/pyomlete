import os

# Several modules build their API clients at import time (`tools._service`,
# `lib.db.vo`, `lib.claude.async_claude`), so importing them under test needs keys to
# exist before the import happens. These are placeholders — every test mocks the
# client itself, and nothing here reaches the network.
os.environ.setdefault("VOYAGE_API_KEY", "test-voyage-key")
os.environ.setdefault("ANTHROPIC_API_KEY", "test-anthropic-key")
os.environ.setdefault("DB_URI", "mongodb://localhost:27017")

import pytest  # noqa: E402


@pytest.fixture(autouse=True)
def no_background_tagging(monkeypatch):
    """Saving a recipe tags it on Haiku in the background. Tests never reach the model."""
    import services.recipes

    calls: list = []
    monkeypatch.setattr(services.recipes, "tag_later", calls.append)
    return calls
