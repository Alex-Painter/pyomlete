import asyncio
import base64
from datetime import datetime, timezone
from types import SimpleNamespace
from typing import ClassVar
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest
from beanie import PydanticObjectId

import main
from lib.types import RecipeJob, RecipeModelResponse
from recipe_import import BlockedURL, FetchFailed
from tests.test_import_from_url import URL, make_scraped, patch_pipeline, structured

RECIPE_ID = "64b7f0c2a1b2c3d4e5f60718"


class FakeJobDocument(RecipeJob):
    """`RecipeJobDocument` over a dict: the real fields, no database."""

    store: ClassVar[dict] = {}

    id: PydanticObjectId | None = None

    async def insert(self):
        self.id = PydanticObjectId()
        self.store[self.id] = self

    async def save(self):
        self.store[self.id] = self

    @classmethod
    async def get(cls, job_id):
        return cls.store.get(job_id)


@pytest.fixture(autouse=True)
def jobs():
    FakeJobDocument.store = {}
    with patch.object(main, "RecipeJobDocument", FakeJobDocument):
        yield FakeJobDocument.store


@pytest.fixture
async def api():
    transport = httpx.ASGITransport(app=main.app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


def saved_recipe() -> AsyncMock:
    """`_save_recipe`, answering with a document that has an id."""
    return AsyncMock(return_value=SimpleNamespace(id=RECIPE_ID))


def model_answering(recipe: RecipeModelResponse | Exception) -> MagicMock:
    """`async_claude`, whose tool runner ends in this recipe or this error."""
    claude = MagicMock()
    runner = claude.beta.messages.tool_runner.return_value
    if isinstance(recipe, Exception):
        runner.until_done = AsyncMock(side_effect=recipe)
    else:
        message = SimpleNamespace(content=[SimpleNamespace(text=recipe.model_dump_json())])
        runner.until_done = AsyncMock(return_value=message)
    return claude


SOUP = RecipeModelResponse(
    title="Leek and potato soup",
    instructions=["Sweat the leeks.", "Simmer and blend."],
    ingredients=[structured(name="leeks")],
)


async def finished(api: httpx.AsyncClient, started: httpx.Response) -> dict:
    """The job as `GET` answers it once its background task has ended."""
    assert started.status_code == 202
    assert started.json()["status"] == "working"
    await asyncio.gather(*list(main._background_tasks))
    response = await api.get(f"/api/recipe-jobs/{started.json()['id']}")
    assert response.status_code == 200
    return response.json()


class TestALinkJob:
    async def test_answers_at_once_and_ends_saved_with_the_recipe_id(self, api):
        ctx, mocks = patch_pipeline(scraped=make_scraped())
        mocks["save"].return_value = SimpleNamespace(id=RECIPE_ID)
        release = asyncio.Event()

        async def slow_fetch(url):
            await release.wait()
            return "<html></html>"

        mocks["fetch"].side_effect = slow_fetch

        with ctx:
            started = await api.post("/api/recipe-jobs/link", json={"url": URL})
            job_id = started.json()["id"]
            working = (await api.get(f"/api/recipe-jobs/{job_id}")).json()
            release.set()
            job = await finished(api, started)

        assert working == {
            "id": job_id, "kind": "link", "status": "working",
            "recipe_id": None, "failure": None,
        }
        assert job == {
            "id": job_id, "kind": "link", "status": "saved",
            "recipe_id": RECIPE_ID, "failure": None,
        }
        assert mocks["save"].call_args.args[1].source_url == URL

    async def test_applies_changes_typed_alongside_the_link(self, api):
        ctx, mocks = patch_pipeline(scraped=make_scraped())
        mocks["save"].return_value = SimpleNamespace(id=RECIPE_ID)
        adapted = SOUP.model_copy(update={"title": "Quorn lasagne"})
        apply_changes = AsyncMock(return_value=adapted)

        with ctx, patch.object(main, "_apply_changes", apply_changes):
            job = await finished(api, await api.post(
                "/api/recipe-jobs/link", json={"url": URL, "changes": "use quorn mince"}
            ))

        assert job["status"] == "saved"
        assert apply_changes.call_args.args[1] == "use quorn mince"
        assert mocks["save"].call_args.args[0].title == "Quorn lasagne"
        # An adapted import is a new recipe, so it never looks for the page.
        mocks["find_one"].assert_not_called()

    async def test_a_page_already_imported_ends_with_that_recipes_id(self, api):
        ctx, mocks = patch_pipeline(existing=SimpleNamespace(id=RECIPE_ID))

        with ctx:
            job = await finished(api, await api.post("/api/recipe-jobs/link", json={"url": URL}))

        assert (job["status"], job["recipe_id"], job["failure"]) == (
            "already_imported", RECIPE_ID, None,
        )
        mocks["fetch"].assert_not_called()

    @pytest.mark.parametrize(
        "pipeline, failure",
        [
            ({"fetch_error": BlockedURL("private address")}, "link_blocked"),
            ({"fetch_error": FetchFailed("timed out")}, "site_did_not_respond"),
            ({"scraped": None}, "no_recipe_on_page"),
            ({"fetch_error": RuntimeError("boom")}, "other"),
        ],
    )
    async def test_each_way_a_link_fails_is_named(self, api, pipeline, failure):
        ctx, mocks = patch_pipeline(**pipeline)

        with ctx, patch.object(main, "_recipe_from_page_text", AsyncMock(return_value=None)):
            job = await finished(api, await api.post("/api/recipe-jobs/link", json={"url": URL}))

        assert (job["status"], job["recipe_id"], job["failure"]) == ("failed", None, failure)
        mocks["save"].assert_not_called()


class TestADescribeJob:
    async def test_ends_saved_with_the_recipe_the_model_wrote(self, api):
        claude, save = model_answering(SOUP), saved_recipe()

        with patch.multiple(
            main,
            async_claude=claude,
            _save_recipe=save,
            _get_category_names=AsyncMock(return_value=["Fresh Produce", "Other"]),
        ):
            job = await finished(api, await api.post(
                "/api/recipe-jobs/describe", json={"prompt": "leek and potato soup"}
            ))

        assert (job["kind"], job["status"], job["recipe_id"]) == ("describe", "saved", RECIPE_ID)
        messages = claude.beta.messages.tool_runner.call_args.kwargs["messages"]
        assert messages[-1] == {"role": "user", "content": "leek and potato soup"}
        assert save.call_args.args[0].title == "Leek and potato soup"

    async def test_a_model_error_is_a_general_failure(self, api):
        with patch.multiple(
            main,
            async_claude=model_answering(RuntimeError("no key")),
            _save_recipe=saved_recipe(),
            _get_category_names=AsyncMock(return_value=["Other"]),
        ):
            job = await finished(api, await api.post(
                "/api/recipe-jobs/describe", json={"prompt": "leek and potato soup"}
            ))

        assert (job["status"], job["recipe_id"], job["failure"]) == ("failed", None, "other")


class TestAPhotosJob:
    async def test_reads_every_photo_as_one_recipe(self, api):
        claude, save = model_answering(SOUP), saved_recipe()

        with patch.multiple(
            main,
            async_claude=claude,
            _save_recipe=save,
            _get_category_names=AsyncMock(return_value=["Other"]),
        ):
            job = await finished(api, await api.post(
                "/api/recipe-jobs/photos",
                files=[
                    ("files", ("page-1.jpg", b"first page", "image/jpeg")),
                    ("files", ("page-2.png", b"second page", "image/png")),
                ],
            ))

        assert (job["kind"], job["status"], job["recipe_id"]) == ("photos", "saved", RECIPE_ID)
        # The upload was closed when the request ended, so these are the bytes read before it.
        claude.beta.messages.tool_runner.assert_called_once()
        content = claude.beta.messages.tool_runner.call_args.kwargs["messages"][0]["content"]
        images = [block["source"] for block in content if block["type"] == "image"]
        assert images == [
            {"type": "base64", "media_type": "image/jpeg",
             "data": base64.standard_b64encode(b"first page").decode()},
            {"type": "base64", "media_type": "image/png",
             "data": base64.standard_b64encode(b"second page").decode()},
        ]

    async def test_a_model_error_is_a_general_failure(self, api):
        with patch.multiple(
            main,
            async_claude=model_answering(RuntimeError("no key")),
            _save_recipe=saved_recipe(),
            _get_category_names=AsyncMock(return_value=["Other"]),
        ):
            job = await finished(api, await api.post(
                "/api/recipe-jobs/photos",
                files=[("files", ("page.jpg", b"page", "image/jpeg"))],
            ))

        assert (job["status"], job["failure"]) == ("failed", "other")


class TestReadingAJob:
    async def test_an_unknown_id_is_not_found(self, api):
        response = await api.get(f"/api/recipe-jobs/{PydanticObjectId()}")

        assert response.status_code == 404

    async def test_a_job_working_past_the_bound_is_answered_as_failed(self, api, jobs):
        """A restart loses the task and leaves the document saying working."""
        job = FakeJobDocument(kind="describe")
        await job.insert()

        job.created_at = datetime.now(timezone.utc) - main.RECIPE_JOB_STALE_AFTER * 0.9
        fresh = (await api.get(f"/api/recipe-jobs/{job.id}")).json()
        # As Mongo returns it: the same instant with its zone dropped.
        job.created_at = (
            datetime.now(timezone.utc) - main.RECIPE_JOB_STALE_AFTER * 1.1
        ).replace(tzinfo=None)
        stale = (await api.get(f"/api/recipe-jobs/{job.id}")).json()

        assert (fresh["status"], fresh["failure"]) == ("working", None)
        assert (stale["status"], stale["failure"]) == ("failed", "other")
        # Decided when read, not written: a task that does finish still has the last word.
        assert jobs[job.id].status == "working"

    async def test_a_job_that_runs_past_the_time_limit_is_cancelled_and_fails(self, api):
        cancelled = asyncio.Event()

        async def never_answers(*_args, **_kwargs):
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        claude = MagicMock()
        claude.beta.messages.tool_runner.return_value.until_done = never_answers
        save = saved_recipe()

        with patch.multiple(
            main,
            async_claude=claude,
            _save_recipe=save,
            _get_category_names=AsyncMock(return_value=["Other"]),
            RECIPE_JOB_TIME_LIMIT=main.RECIPE_JOB_TIME_LIMIT * 0,
        ):
            job = await finished(api, await api.post(
                "/api/recipe-jobs/describe", json={"prompt": "leek and potato soup"}
            ))

        assert (job["status"], job["failure"]) == ("failed", "other")
        assert cancelled.is_set()
        save.assert_not_called()
