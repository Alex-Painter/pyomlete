from unittest.mock import AsyncMock, MagicMock, patch

from ingredient_service import IngredientService, _SIMILARITY_THRESHOLD


async def _find_similar_with_mocks(ingredient_names, aggregate_docs):
    """Helper: create a service, run find_similar, return (results, mocks)."""
    with patch("ingredient_service.voyageai.Client"):
        svc = IngredientService()

    embeddings = [[float(i)] * 10 for i in range(len(ingredient_names))] or [[0.1] * 10]
    vo_mock = MagicMock()
    embed_result = MagicMock()
    embed_result.embeddings = embeddings
    vo_mock.embed.return_value = embed_result
    svc._vo = vo_mock

    cursor_mock = AsyncMock()
    cursor_mock.to_list = AsyncMock(return_value=aggregate_docs)

    with patch("ingredient_service.IngredientDocument") as MockDoc:
        MockDoc.aggregate.return_value = cursor_mock
        results = await svc.find_similar(ingredient_names)

    return results


class TestFindSimilar:
    async def test_returns_empty_list_for_empty_input(self):
        with patch("ingredient_service.voyageai.Client"):
            svc = IngredientService()
        svc._vo = MagicMock()

        results = await svc.find_similar([])

        assert results == []
        svc._vo.embed.assert_not_called()

    async def test_returns_empty_matches_when_no_ingredients_stored(self):
        results = await _find_similar_with_mocks(["garlic"], aggregate_docs=[])

        assert len(results) == 1
        assert results[0].query == "garlic"
        assert results[0].matches == []

    async def test_returns_matches_above_threshold(self):
        high_score_doc = {"name": "garlic clove", "score": 0.95, "unit": "cloves"}
        results = await _find_similar_with_mocks(
            ["garlic"], aggregate_docs=[high_score_doc]
        )

        assert len(results[0].matches) == 1
        assert results[0].matches[0].name == "garlic clove"
        assert results[0].matches[0].score == 0.95

    async def test_excludes_matches_below_threshold(self):
        low_score_doc = {"name": "garlic powder", "score": 0.85, "unit": "tsp"}
        results = await _find_similar_with_mocks(
            ["garlic"], aggregate_docs=[low_score_doc]
        )

        assert results[0].matches == []

    async def test_filters_mixed_scores(self):
        docs = [
            {"name": "garlic clove", "score": 0.97, "unit": "cloves"},
            {"name": "garlic powder", "score": 0.88, "unit": "tsp"},
            {"name": "black garlic", "score": _SIMILARITY_THRESHOLD, "unit": "cloves"},
        ]
        results = await _find_similar_with_mocks(["garlic"], aggregate_docs=docs)

        match_names = [m.name for m in results[0].matches]
        assert "garlic clove" in match_names
        assert "black garlic" in match_names  # exactly at threshold — included
        assert "garlic powder" not in match_names

    async def test_returns_one_query_match_per_ingredient(self):
        results = await _find_similar_with_mocks(
            ["garlic", "onion", "salt"], aggregate_docs=[]
        )

        assert len(results) == 3
        assert {r.query for r in results} == {"garlic", "onion", "salt"}

    async def test_passes_all_names_to_voyage_embed(self):
        with patch("ingredient_service.voyageai.Client"):
            svc = IngredientService()

        vo_mock = MagicMock()
        embed_result = MagicMock()
        embed_result.embeddings = [[0.1] * 10, [0.2] * 10]
        vo_mock.embed.return_value = embed_result
        svc._vo = vo_mock

        cursor_mock = AsyncMock()
        cursor_mock.to_list = AsyncMock(return_value=[])

        with patch("ingredient_service.IngredientDocument") as MockDoc:
            MockDoc.aggregate.return_value = cursor_mock
            await svc.find_similar(["garlic", "onion"])

        vo_mock.embed.assert_called_once()
        call_kwargs = vo_mock.embed.call_args
        assert call_kwargs.kwargs["texts"] == ["garlic", "onion"]
