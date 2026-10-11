import asyncio
import base64
import logging
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from typing import ClassVar
from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import httpx
import pytest
from pymongo.errors import DuplicateKeyError

import main
from lib.types import RecipeJob, RecipeModelResponse
from recipe_import import BlockedURL, FetchFailed
from tests.test_import_from_url import URL, make_scraped, patch_pipeline, structured

RECIPE_ID = "64b7f0c2a1b2c3d4e5f60718"
KEY = "0b9f6f0e-5a52-4b53-9d4a-2f1f3c1e7a10"


class FakeJobDocument(RecipeJob):
    """`RecipeJobDocument` over a dict: the real fields, no database.

    Like Mongo it refuses a second document with the same id, and every call
    gives way first, so two requests at once interleave as they would there.
    """

    store: ClassVar[dict] = {}
    #: Saves that fail before one is let through.
    failing_saves: ClassVar[int] = 0
    hanging_saves: ClassVar[int] = 0

    id: str

    async def insert(self):
        await asyncio.sleep(0)
        if self.id in self.store:
            raise DuplicateKeyError("E11000 duplicate key error")
        self.store[self.id] = self.model_copy()

    async def save(self):
        await asyncio.sleep(0)
        if type(self).hanging_saves > 0:
            type(self).hanging_saves -= 1
            await asyncio.sleep(3600)
        if type(self).failing_saves > 0:
            type(self).failing_saves -= 1
            raise ConnectionError("mongo is away")
        self.store[self.id] = self.model_copy()

    @classmethod
    async def get(cls, job_id):
        await asyncio.sleep(0)
        return cls.store.get(job_id)


@pytest.fixture(autouse=True)
def jobs():
    FakeJobDocument.store = {}
    FakeJobDocument.failing_saves = 0
    FakeJobDocument.hanging_saves = 0
    # The cap's own state, so a test that dies mid-start cannot shrink the cap for the next.
    main._recipe_jobs_starting.clear()
    main._recipe_job_tasks.clear()
    with patch.multiple(main, RecipeJobDocument=FakeJobDocument, RECIPE_JOB_WRITE_PAUSES=(0, 0, 0)):
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
    await asyncio.gather(*list(main._recipe_job_tasks))
    response = await api.get(f"/api/recipe-jobs/{started.json()['key']}")
    assert response.status_code == 200
    return response.json()


def describe(api: httpx.AsyncClient, key: str = KEY):
    return api.put(f"/api/recipe-jobs/{key}/describe", json={"prompt": "leek and potato soup"})


def a_model(recipe=None, **patches):
    """Everything a describe or photos job touches, with the model answering `recipe`."""
    return patch.multiple(main, **{
        "async_claude": model_answering(recipe or SOUP),
        "_get_category_names": AsyncMock(return_value=["Other"]),
        "_save_recipe": saved_recipe(),
        **patches,
    })


def a_model_that_never_answers(reached: asyncio.Event | None = None) -> MagicMock:
    async def never_answers(*_args, **_kwargs):
        if reached:
            reached.set()
        await asyncio.Event().wait()

    claude = MagicMock()
    claude.beta.messages.tool_runner.return_value.until_done = never_answers
    return claude


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
            started = await api.put(
                f"/api/recipe-jobs/{KEY}/link", json={"url": URL})
            working = (await api.get(f"/api/recipe-jobs/{KEY}")).json()
            release.set()
            job = await finished(api, started)

        assert working == {
            "key": KEY, "kind": "link", "status": "working",
            "recipe_id": None, "failure": None,
        }
        assert job == {
            "key": KEY, "kind": "link", "status": "saved",
            "recipe_id": RECIPE_ID, "failure": None,
        }
        assert mocks["save"].call_args.args[1].source_url == URL

    async def test_applies_changes_typed_alongside_the_link(self, api):
        ctx, mocks = patch_pipeline(scraped=make_scraped())
        mocks["save"].return_value = SimpleNamespace(id=RECIPE_ID)
        adapted = SOUP.model_copy(update={"title": "Quorn lasagne"})
        apply_changes = AsyncMock(return_value=adapted)

        with ctx, patch.object(main, "_apply_changes", apply_changes):
            job = await finished(api, await api.put(
                f"/api/recipe-jobs/{KEY}/link", json={"url": URL, "changes": "use quorn mince"}
            ))

        assert job["status"] == "saved"
        assert apply_changes.call_args.args[1] == "use quorn mince"
        assert mocks["save"].call_args.args[0].title == "Quorn lasagne"
        # An adapted import is a new recipe, so it never looks for the page.
        mocks["find_one"].assert_not_called()

    async def test_a_page_already_imported_ends_with_that_recipes_id(self, api):
        ctx, mocks = patch_pipeline(existing=SimpleNamespace(id=RECIPE_ID))

        with ctx:
            job = await finished(api, await api.put(
                f"/api/recipe-jobs/{KEY}/link", json={"url": URL}))

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
            job = await finished(api, await api.put(
                f"/api/recipe-jobs/{KEY}/link", json={"url": URL}))

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
            job = await finished(api, await api.put(
                f"/api/recipe-jobs/{KEY}/describe", json={"prompt": "leek and potato soup"}
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
            job = await finished(api, await api.put(
                f"/api/recipe-jobs/{KEY}/describe", json={"prompt": "leek and potato soup"}
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
            job = await finished(api, await api.put(
                f"/api/recipe-jobs/{KEY}/photos",
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
            job = await finished(api, await api.put(
                f"/api/recipe-jobs/{KEY}/photos",
                files=[("files", ("page.jpg", b"page", "image/jpeg"))],
            ))

        assert (job["status"], job["failure"]) == ("failed", "other")


class TestStartingAJob:
    async def test_a_repeat_answers_with_the_same_job_and_makes_nothing_more(self, api, jobs):
        claude = a_model_that_never_answers()

        with a_model(async_claude=claude):
            first = await describe(api)
            again = await describe(api)
            # The key is the job, whatever a later start says it wants.
            other = await api.put(f"/api/recipe-jobs/{KEY}/link", json={"url": URL})
            await main._end_running_work()

        assert (first.status_code, again.status_code, other.status_code) == (202, 200, 200)
        assert again.json() == first.json() == {
            "key": KEY, "kind": "describe", "status": "working",
            "recipe_id": None, "failure": None,
        }
        assert other.json()["kind"] == "describe"
        assert list(jobs) == [KEY]
        claude.beta.messages.tool_runner.assert_called_once()

    async def test_a_repeat_after_the_job_ended_answers_with_how_it_ended(self, api):
        save = saved_recipe()

        with a_model(_save_recipe=save):
            await finished(api, await describe(api))
            again = await describe(api)
            await asyncio.gather(*list(main._recipe_job_tasks))

        assert again.status_code == 200
        assert (again.json()["status"], again.json()["recipe_id"]) == ("saved", RECIPE_ID)
        save.assert_called_once()

    async def test_two_starts_at_once_make_one_job(self, api, jobs):
        claude, save = model_answering(SOUP), saved_recipe()

        with a_model(async_claude=claude, _save_recipe=save):
            # Both look before either inserts, so the second insert is the one Mongo refuses.
            both = await asyncio.gather(describe(api), describe(api))
            await asyncio.gather(*list(main._recipe_job_tasks))

        assert sorted(r.status_code for r in both) == [200, 202]
        assert [r.json()["key"] for r in both] == [KEY, KEY]
        assert list(jobs) == [KEY]
        claude.beta.messages.tool_runner.assert_called_once()
        save.assert_called_once()

    async def test_a_key_is_a_uuid_and_is_the_same_job_however_it_is_spelt(self, api, jobs):
        with a_model():
            junk = await describe(api, "job-1")
            await finished(api, await describe(api, KEY.upper()))
            job = await api.get(f"/api/recipe-jobs/{KEY}")

        assert junk.status_code == 422
        assert job.json()["status"] == "saved"
        assert list(jobs) == [KEY]

    async def test_only_so_many_jobs_work_at_once_and_one_more_is_refused(self, api, jobs):
        claude = a_model_that_never_answers()
        keys = [str(uuid4()) for _ in range(main.MAX_WORKING_RECIPE_JOBS + 1)]

        with a_model(async_claude=claude):
            started = [await describe(api, key) for key in keys[:-1]]
            refused = await describe(api, keys[-1])
            # A job already running is still answered for, however busy it is.
            repeat = await describe(api, keys[0])
            await main._end_running_work()

        assert [r.status_code for r in started] == [202] * main.MAX_WORKING_RECIPE_JOBS
        assert refused.status_code == 429
        assert refused.headers["retry-after"] == "30"
        assert repeat.status_code == 200
        assert keys[-1] not in jobs
        assert claude.beta.messages.tool_runner.call_count == main.MAX_WORKING_RECIPE_JOBS

    async def test_starts_that_arrive_together_cannot_pass_the_limit_together(self, api, jobs):
        claude = a_model_that_never_answers()
        keys = [str(uuid4()) for _ in range(main.MAX_WORKING_RECIPE_JOBS * 2)]

        with a_model(async_claude=claude):
            answers = await asyncio.gather(*(describe(api, key) for key in keys))
            await main._end_running_work()

        statuses = sorted(r.status_code for r in answers)
        assert statuses == [202] * main.MAX_WORKING_RECIPE_JOBS + [429] * main.MAX_WORKING_RECIPE_JOBS
        assert len(jobs) == main.MAX_WORKING_RECIPE_JOBS
        assert main._recipe_jobs_starting == set()

    async def test_a_job_whose_task_died_with_its_server_holds_no_place(self, api, jobs):
        for _ in range(main.MAX_WORKING_RECIPE_JOBS):
            orphan = FakeJobDocument(id=str(uuid4()), kind="describe")
            jobs[orphan.id] = orphan

        with a_model():
            response = await describe(api, str(uuid4()))
            await asyncio.gather(*list(main._recipe_job_tasks))

        assert response.status_code == 202

    async def test_a_repeat_of_a_key_still_being_started_is_not_refused_as_busy(self, api, jobs):
        claude = a_model_that_never_answers()
        keys = [str(uuid4()) for _ in range(main.MAX_WORKING_RECIPE_JOBS)]

        with a_model(async_claude=claude):
            for key in keys[:-1]:
                await describe(api, key)
            # The last place is taken by a start and its repeat arriving together.
            first, repeat = await asyncio.gather(describe(api, keys[-1]), describe(api, keys[-1]))
            await main._end_running_work()

        assert sorted([first.status_code, repeat.status_code]) == [200, 202]
        assert claude.beta.messages.tool_runner.call_count == main.MAX_WORKING_RECIPE_JOBS
        assert main._recipe_jobs_starting == set()

    @pytest.mark.parametrize(
        "photos",
        [
            [b"page"] * (main.MAX_JOB_PHOTOS + 1),
            [b"page", b"x" * (main.MAX_JOB_PHOTO_BYTES + 1)],
        ],
        ids=["too many", "one too large"],
    )
    async def test_photos_past_the_bounds_are_refused_and_start_nothing(self, api, jobs, photos):
        claude = model_answering(SOUP)

        with a_model(async_claude=claude):
            response = await api.put(
                f"/api/recipe-jobs/{KEY}/photos",
                files=[("files", (f"page-{i}.jpg", data, "image/jpeg")) for i, data in enumerate(photos)],
            )

        assert response.status_code == 413
        assert jobs == {}
        claude.beta.messages.tool_runner.assert_not_called()

    @pytest.mark.parametrize(
        "files",
        [
            [("files", ("page.jpg", b"", "image/jpeg"))],
            [("files", ("notes.txt", b"not a photo", "text/plain"))],
            [("files", ("page.heic", b"page", "image/heic"))],
        ],
        ids=["empty", "not an image", "an image the model does not read"],
    )
    async def test_a_photo_that_is_empty_or_not_an_image_starts_nothing(self, api, jobs, files):
        claude = model_answering(SOUP)

        with a_model(async_claude=claude):
            response = await api.put(f"/api/recipe-jobs/{KEY}/photos", files=files)

        assert response.status_code == 422
        assert jobs == {}
        claude.beta.messages.tool_runner.assert_not_called()

    @pytest.mark.parametrize("media_type", sorted(main.JOB_PHOTO_TYPES))
    async def test_each_type_the_model_reads_is_taken(self, api, media_type):
        with a_model():
            response = await api.put(
                f"/api/recipe-jobs/{KEY}/photos", files=[("files", ("page", b"page", media_type))]
            )
            await asyncio.gather(*list(main._recipe_job_tasks))

        assert response.status_code == 202

    async def test_photos_at_the_bounds_are_taken(self, api):
        with a_model():
            job = await finished(api, await api.put(
                f"/api/recipe-jobs/{KEY}/photos",
                files=[("files", ("page.jpg", b"x" * main.MAX_JOB_PHOTO_BYTES, "image/jpeg"))]
                * main.MAX_JOB_PHOTOS,
            ))

        assert job["status"] == "saved"


class TestHowAJobEndsIsWritten:
    async def test_a_write_mongo_refuses_is_tried_again_and_logged(self, api, jobs, caplog):
        FakeJobDocument.failing_saves = 2

        with a_model(), caplog.at_level(logging.ERROR, logger="main"):
            job = await finished(api, await describe(api))

        assert (job["status"], job["recipe_id"]) == ("saved", RECIPE_ID)
        refusals = [r.getMessage() for r in caplog.records if "could not be written" in r.getMessage()]
        assert refusals == [f"Recipe job {KEY} ended saved (recipe {RECIPE_ID}) and that could not be written"] * 2

    async def test_a_write_that_hangs_is_given_up_on_and_tried_again(self, api, jobs, monkeypatch):
        monkeypatch.setattr(main, "RECIPE_JOB_WRITE_TIMEOUT", 0.01)
        monkeypatch.setattr(main, "RECIPE_JOB_WRITE_PAUSES", (0, 0, 0))
        FakeJobDocument.hanging_saves = 1

        with a_model():
            job = await finished(api, await describe(api))

        assert (job["status"], job["recipe_id"]) == ("saved", RECIPE_ID)

    async def test_a_write_that_never_lands_leaves_the_job_working_for_the_stale_rule(self, api, jobs):
        FakeJobDocument.failing_saves = len(main.RECIPE_JOB_WRITE_PAUSES)

        with a_model():
            job = await finished(api, await describe(api))

        assert job["status"] == "working"

    async def test_the_time_limit_running_out_does_not_stop_the_write(self, api, jobs):
        """The limit is over the making only. A slow write is still made."""
        FakeJobDocument.failing_saves = 2
        limit = timedelta(seconds=0.05)

        with a_model(RECIPE_JOB_TIME_LIMIT=limit, RECIPE_JOB_WRITE_PAUSES=(0.05,) * 3):
            job = await finished(api, await describe(api))

        assert job["status"] == "saved"

    async def test_shutdown_fails_the_jobs_it_is_running_at_once(self, api, jobs):
        reached = asyncio.Event()
        save = saved_recipe()

        with a_model(async_claude=a_model_that_never_answers(reached), _save_recipe=save):
            started = await describe(api)
            await reached.wait()
            await main._end_running_work()
            job = (await api.get(f"/api/recipe-jobs/{KEY}")).json()

        assert started.status_code == 202
        assert (job["status"], job["failure"]) == ("failed", "other")
        assert jobs[KEY].status == "failed"
        assert not main._recipe_job_tasks
        save.assert_not_called()

    async def test_shutdown_during_the_write_lets_a_saved_job_say_saved(self, api, jobs):
        writing = asyncio.Event()
        release = asyncio.Event()

        async def slow_save(self):
            writing.set()
            await release.wait()
            jobs[self.id] = self.model_copy()

        with a_model(), patch.object(FakeJobDocument, "save", slow_save):
            await describe(api)
            await writing.wait()
            ending = asyncio.create_task(main._end_running_work())
            await asyncio.sleep(0.01)
            still_waiting = not ending.done()
            release.set()
            await ending

        assert still_waiting
        assert (jobs[KEY].status, jobs[KEY].recipe_id) == ("saved", RECIPE_ID)

    async def test_the_app_shutting_down_ends_its_jobs(self, jobs):
        reached = asyncio.Event()
        closed = MagicMock()

        with (
            a_model(async_claude=a_model_that_never_answers(reached)),
            patch.multiple(main, get_motor_client=MagicMock(return_value=closed), init_beanie=AsyncMock()),
        ):
            async with main.lifespan(main.app):
                transport = httpx.ASGITransport(app=main.app)
                async with httpx.AsyncClient(transport=transport, base_url="http://test") as api:
                    await describe(api)
                await reached.wait()

        assert jobs[KEY].status == "failed"
        closed.close.assert_called_once()


class TestReadingAJob:
    async def test_a_key_never_started_is_not_found(self, api):
        response = await api.get(f"/api/recipe-jobs/{uuid4()}")

        assert response.status_code == 404

    async def test_a_job_working_past_the_bound_is_answered_as_failed(self, api, jobs):
        """A restart loses the task and leaves the document saying working."""
        job = FakeJobDocument(id=KEY, kind="describe")
        jobs[KEY] = job

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

        with a_model(
            async_claude=claude,
            _save_recipe=save,
            RECIPE_JOB_TIME_LIMIT=main.RECIPE_JOB_TIME_LIMIT * 0,
        ):
            job = await finished(api, await describe(api))

        assert (job["status"], job["failure"]) == ("failed", "other")
        assert cancelled.is_set()
        save.assert_not_called()
