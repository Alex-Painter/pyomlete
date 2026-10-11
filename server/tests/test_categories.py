"""`PUT /api/settings/categories` stores a clean aisle list whatever it is sent."""

from unittest.mock import AsyncMock, patch

import httpx
import pytest

import main
from data_models import CategoryConfig


class FakeSettings:
    """`UserSettingsDocument`, kept in memory."""

    def __init__(self, *names: str):
        self.categories = [CategoryConfig(name=name, order=order) for order, name in enumerate(names)]
        self.save = AsyncMock()


@pytest.fixture
def settings():
    held = FakeSettings("Bakery", "Dairy")
    with patch.object(main, "_get_or_create_settings", AsyncMock(return_value=held)):
        yield held


@pytest.fixture
async def api():
    transport = httpx.ASGITransport(app=main.app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


def numbered(*names: str) -> dict:
    return {"categories": [{"name": name, "order": order} for order, name in enumerate(names)]}


def put(api: httpx.AsyncClient, body: dict):
    return api.put("/api/settings/categories", json=body)


async def test_a_clean_list_is_stored_as_sent(api, settings):
    body = numbered("Fresh Produce", "Meat & Fish", "Other")

    answer = await put(api, body)

    assert answer.status_code == 200
    assert answer.json() == body["categories"]
    assert [c.model_dump() for c in settings.categories] == body["categories"]
    settings.save.assert_awaited_once()


async def test_names_are_trimmed(api, settings):
    await put(api, numbered("  Bakery ", "Dairy\n"))

    assert [c.name for c in settings.categories] == ["Bakery", "Dairy"]


async def test_empty_and_all_space_names_are_dropped(api, settings):
    answer = await put(api, numbered("Bakery", "", "   ", "Dairy"))

    assert answer.status_code == 200
    assert answer.json() == [{"name": "Bakery", "order": 0}, {"name": "Dairy", "order": 3}]


async def test_a_name_repeated_in_any_case_keeps_its_first_place(api, settings):
    await put(api, numbered("Bakery", "Dairy", "bakery", " DAIRY ", "Frozen"))

    assert [(c.name, c.order) for c in settings.categories] == [("Bakery", 0), ("Dairy", 1), ("Frozen", 4)]


async def test_a_list_with_nothing_left_is_stored_empty(api, settings):
    answer = await put(api, numbered(" "))

    assert answer.status_code == 200
    assert settings.categories == []


async def test_what_is_stored_is_what_a_get_answers(api, settings):
    await put(api, numbered("Bakery", "BAKERY", "Drinks"))

    assert (await api.get("/api/settings/categories")).json() == [
        {"name": "Bakery", "order": 0},
        {"name": "Drinks", "order": 2},
    ]
