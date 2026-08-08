from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException

import main
from data_models import ItemSource
from lib.types import ImportFromUrlRequest, IngredientModelResponse
from recipe_import import BlockedURL, FetchFailed, IngredientGroup, ScrapedRecipe

URL = "https://www.bbcgoodfood.com/recipes/classic-lasagne"


def make_scraped(**overrides) -> ScrapedRecipe:
    base = dict(
        title="Classic Lasagne",
        instructions=["Fry the onions.", "Bake for 45 mins."],
        ingredients=["2 onions, finely chopped", "500g beef mince"],
        source_url=URL,
        servings=6,
        prep_minutes=30,
        cook_minutes=90,
        total_minutes=120,
        image_url="https://images.example.com/lasagne.jpg",
        source_name="bbcgoodfood.com",
        description="A proper family favourite.",
        cuisine="Italian",
    )
    base.update(overrides)
    return ScrapedRecipe(**base)


def structured(**overrides) -> IngredientModelResponse:
    base = {"name": "onions", "unit": "", "amount": 2.0, "is_new": True}
    base.update(overrides)
    return IngredientModelResponse(**base)


def patch_pipeline(
    *,
    existing=None,
    html="<html></html>",
    scraped=None,
    ingredients=None,
    fetch_error=None,
):
    """Patch every collaborator of the import endpoint.

    Returns a context manager yielding the mocks the tests assert against.
    """
    recipe_doc = MagicMock()
    recipe_doc.find_one = AsyncMock(return_value=existing)

    fetch = AsyncMock(side_effect=fetch_error) if fetch_error else AsyncMock(return_value=html)
    structurer = AsyncMock(return_value=ingredients if ingredients is not None else [structured()])
    save = AsyncMock(return_value={"saved": True})

    return (
        patch.multiple(
            main,
            RecipeDocument=recipe_doc,
            fetch_page=fetch,
            scrape=MagicMock(return_value=scraped),
            structure_ingredients=structurer,
            _save_recipe=save,
            _get_category_names=AsyncMock(return_value=["Fresh Produce", "Other"]),
        ),
        {"find_one": recipe_doc.find_one, "fetch": fetch, "structurer": structurer, "save": save},
    )


class TestImportFromUrl:
    async def test_saves_a_scraped_recipe_with_its_metadata(self):
        ctx, mocks = patch_pipeline(scraped=make_scraped())

        with ctx:
            await main.import_recipe_from_url(ImportFromUrlRequest(url=URL))

        recipe, metadata = mocks["save"].call_args.args
        assert recipe.title == "Classic Lasagne"
        assert recipe.instructions == ["Fry the onions.", "Bake for 45 mins."]
        assert metadata.source_url == URL
        assert metadata.image_url == "https://images.example.com/lasagne.jpg"
        assert metadata.servings == 6
        assert metadata.total_minutes == 120
        assert metadata.cuisine == "Italian"

    async def test_passes_the_free_text_lines_to_the_structurer(self):
        groups = [IngredientGroup(purpose="For the sauce", ingredients=["2 onions"])]
        ctx, mocks = patch_pipeline(scraped=make_scraped(ingredient_groups=groups))

        with ctx:
            await main.import_recipe_from_url(ImportFromUrlRequest(url=URL))

        args, kwargs = mocks["structurer"].call_args
        assert args[0] == ["2 onions, finely chopped", "500g beef mince"]
        assert kwargs["groups"] == groups

    async def test_instructions_come_through_verbatim(self):
        """The whole point of scraping first: the steps are the author's."""
        steps = ["Do the thing exactly like this.", "Then this."]
        ctx, mocks = patch_pipeline(scraped=make_scraped(instructions=steps))

        with ctx:
            await main.import_recipe_from_url(ImportFromUrlRequest(url=URL))

        assert mocks["save"].call_args.args[0].instructions == steps

    async def test_returns_409_and_the_existing_id_for_a_repeat_import(self):
        existing = MagicMock()
        existing.id = "abc123"
        ctx, mocks = patch_pipeline(existing=existing)

        with ctx, pytest.raises(HTTPException) as exc:
            await main.import_recipe_from_url(ImportFromUrlRequest(url=URL))

        assert exc.value.status_code == 409
        assert exc.value.detail["recipe_id"] == "abc123"
        mocks["fetch"].assert_not_called()

    async def test_blocked_url_is_a_client_error(self):
        ctx, _ = patch_pipeline(fetch_error=BlockedURL("resolves to non-public address"))

        with ctx, pytest.raises(HTTPException) as exc:
            await main.import_recipe_from_url(
                ImportFromUrlRequest(url="http://169.254.169.254/latest/meta-data/")
            )

        assert exc.value.status_code == 400

    async def test_unreachable_source_is_a_gateway_error(self):
        ctx, _ = patch_pipeline(fetch_error=FetchFailed("connection timed out"))

        with ctx, pytest.raises(HTTPException) as exc:
            await main.import_recipe_from_url(ImportFromUrlRequest(url=URL))

        assert exc.value.status_code == 502

    async def test_falls_back_to_the_model_when_nothing_is_published(self):
        ctx, mocks = patch_pipeline(scraped=None, html="<html><body>a blog</body></html>")
        fallback = main.RecipeModelResponse(
            title="Blog Lasagne", instructions=["Cook it."], ingredients=[structured()]
        )

        with ctx, patch.object(
            main, "_recipe_from_page_text", AsyncMock(return_value=fallback)
        ) as model:
            await main.import_recipe_from_url(ImportFromUrlRequest(url=URL))

        model.assert_awaited_once()
        recipe, metadata = mocks["save"].call_args.args
        assert recipe.title == "Blog Lasagne"
        # Nothing was published, so only provenance is recorded.
        assert metadata.source_url == URL
        assert metadata.source_name == "www.bbcgoodfood.com"
        assert metadata.image_url is None
        assert metadata.servings is None

    async def test_returns_404_when_the_page_has_no_recipe(self):
        ctx, mocks = patch_pipeline(scraped=None)

        with ctx, patch.object(
            main, "_recipe_from_page_text", AsyncMock(return_value=None)
        ), pytest.raises(HTTPException) as exc:
            await main.import_recipe_from_url(ImportFromUrlRequest(url=URL))

        assert exc.value.status_code == 404
        mocks["save"].assert_not_called()

    async def test_dedup_lookup_uses_the_canonical_url(self):
        ctx, mocks = patch_pipeline(scraped=make_scraped())

        with ctx:
            await main.import_recipe_from_url(
                ImportFromUrlRequest(url=f"  {URL}#method  ")
            )

        assert mocks["save"].call_args.args[1].source_url == URL


class TestEndToEndAgainstAFixture:
    """The one test that runs the real scraper through the real endpoint.

    Everything above mocks `scrape`, which means none of it would notice the
    two halves drifting apart. Only the model call and the save are stubbed
    here — the page is parsed for real.
    """

    async def test_a_real_page_reaches_the_structurer_and_the_save(self):
        html = (Path(__file__).parent / "fixtures" / "recipe_jsonld.html").read_text()
        recipe_doc = MagicMock()
        recipe_doc.find_one = AsyncMock(return_value=None)
        structurer = AsyncMock(return_value=[structured()])
        save = AsyncMock(return_value={"saved": True})

        with patch.multiple(
            main,
            RecipeDocument=recipe_doc,
            fetch_page=AsyncMock(return_value=html),
            structure_ingredients=structurer,
            _save_recipe=save,
            _get_category_names=AsyncMock(return_value=["Fresh Produce", "Other"]),
        ):
            await main.import_recipe_from_url(ImportFromUrlRequest(url=URL))

        # Free-text lines went to stage 2, not structured objects.
        lines = structurer.call_args.args[0]
        assert lines and all(isinstance(line, str) for line in lines)

        recipe, metadata = save.call_args.args
        assert recipe.title
        assert recipe.instructions
        assert metadata.source_url == URL
        assert metadata.total_minutes is not None


class TestCanonicalUrl:
    def test_drops_the_fragment(self):
        assert main._canonical_url(f"{URL}#ingredients") == URL

    def test_trims_whitespace(self):
        assert main._canonical_url(f"  {URL}  ") == URL

    def test_keeps_the_query_string(self):
        """Plenty of sites carry the recipe id in the query."""
        url = "https://example.com/print?recipe=1234"

        assert main._canonical_url(url) == url


class TestPageText:
    def test_strips_scripts_and_styles(self):
        html = (
            "<html><head><style>body{color:red}</style>"
            "<script>var x = 1;</script></head>"
            "<body><h1>Lasagne</h1><p>Fry the onions.</p></body></html>"
        )

        text = main._page_text(html)

        assert "Lasagne" in text
        assert "Fry the onions." in text
        assert "var x" not in text
        assert "color:red" not in text

    def test_drops_blank_lines(self):
        text = main._page_text("<p>one</p>\n\n\n<p>two</p>")

        assert text == "one\ntwo"

    def test_truncates_a_long_page(self):
        html = "<p>" + ("word " * 20000) + "</p>"

        assert len(main._page_text(html)) == main._FALLBACK_TEXT_CHARS


class TestTotalAmount:
    """The list-merge arithmetic now that `amount` can be unset."""

    def test_sums_quantified_sources(self):
        sources = [ItemSource(amount=200.0), ItemSource(amount=100.5)]

        assert main._total_amount(sources) == 300.5

    def test_ignores_unquantified_sources(self):
        sources = [ItemSource(amount=200.0), ItemSource(amount=None)]

        assert main._total_amount(sources) == 200.0

    def test_stays_unquantified_when_no_source_has_an_amount(self):
        sources = [ItemSource(amount=None), ItemSource(amount=None)]

        assert main._total_amount(sources) is None

    def test_handles_an_empty_source_list(self):
        assert main._total_amount([]) is None
