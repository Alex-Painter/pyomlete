"""Chef can do anything the person can: every route that changes data has a Chef tool.

A new route that changes data fails this test until it gets a tool in
chef/chat.py, or a reason here why Chef doesn't need one (docs/PRD_CHEF.md).
"""

from fastapi.routing import APIRoute

import main
from chef import chat

CHANGES = {"POST", "PUT", "PATCH", "DELETE"}

# Each route that changes data, and the tool that does the same.
ROUTE_TOOLS = {
    ("POST", "/api/recipes/generate/"): "create_recipe",
    ("POST", "/api/recipes/extract-from-images/"): "create_recipe_from_photos",
    ("POST", "/api/recipes/import-from-url/"): "import_recipe",
    ("PATCH", "/api/recipes/{recipe_id}/rating"): "rate_recipe",
    ("PUT", "/api/recipes/{recipe_id}"): "update_recipe",
    ("DELETE", "/api/recipes/{recipe_id}"): "delete_recipe",
    ("PATCH", "/api/recipes/{recipe_id}/ingredients/{ingredient_index}/exclude"): "set_ingredient_on_lists",
    ("POST", "/api/lists/"): "create_list",
    ("PATCH", "/api/lists/{list_id}"): "rename_list",
    ("DELETE", "/api/lists/{list_id}"): "delete_list",
    ("POST", "/api/lists/{list_id}/duplicate"): "duplicate_list",
    ("PUT", "/api/settings/categories"): "set_aisles",
    ("PUT", "/api/settings/plan"): "set_week_start",
    ("PUT", "/api/lists/{list_id}/days/{day}"): "plan_day",
    ("POST", "/api/lists/{list_id}/recipes"): "add_recipe_to_list",
    ("DELETE", "/api/lists/{list_id}/recipes/{recipe_id}"): "remove_recipe_from_list",
    ("PUT", "/api/lists/{list_id}/recipes/{recipe_id}/cooked"): "mark_cooked",
    ("POST", "/api/lists/{list_id}/items"): "add_item",
    ("PUT", "/api/lists/{list_id}/items/reorder"): "reorder_items",
    ("PATCH", "/api/lists/{list_id}/items/{item_id}"): "update_item",
    ("DELETE", "/api/lists/{list_id}/items/{item_id}"): "delete_item",
    ("PUT", "/api/meals/{key}"): "log_meal",
    ("POST", "/api/preferences"): "remember",
    ("PATCH", "/api/preferences/{pref_id}"): "forget",
}

# Routes that change data with no tool of their own, and why.
NO_TOOL = {
    # Answers a question; it only fills the ingredient cache on the way.
    ("POST", "/api/categorize"): "add_item files an item when no aisle is given",
    # The same recipe making as the tools above, started as a job for a phone
    # that may drop a long request. Chef's tools wait for the recipe instead.
    ("PUT", "/api/recipe-jobs/{key}/link"): "import_recipe",
    ("PUT", "/api/recipe-jobs/{key}/describe"): "create_recipe",
    ("PUT", "/api/recipe-jobs/{key}/photos"): "create_recipe_from_photos",
    # Discover cards are Chef's own ideas. In chat Chef suggests in its reply
    # and saves an idea with create_recipe or import_recipe.
    ("POST", "/api/suggestions/"): "Chef's own output",
    ("POST", "/api/suggestions/refresh"): "Chef's own output",
    ("POST", "/api/suggestions/clear"): "Chef's own output",
    ("PATCH", "/api/suggestions/{suggestion_id}"): "Chef's own output",
    ("POST", "/api/suggestions/{suggestion_id}/save"): "create_recipe, import_recipe",
    # Chef itself.
    ("POST", "/api/chef/chat"): "Chef",
    ("POST", "/api/chef/actions/{action_id}/undo"): "Undo is the person's, not Chef's",
}


def changing_routes() -> set[tuple[str, str]]:
    return {
        (method, route.path)
        for route in main.app.routes
        if isinstance(route, APIRoute)
        for method in route.methods & CHANGES
    }


def test_every_route_that_changes_data_has_a_chef_tool():
    missing = changing_routes() - ROUTE_TOOLS.keys() - NO_TOOL.keys()
    assert not missing, f"Give these a Chef tool in chef/chat.py: {sorted(missing)}"


def test_the_tools_named_exist():
    tools = set(chat.agent._function_toolset.tools)
    assert set(ROUTE_TOOLS.values()) <= tools


def test_nothing_listed_is_stale():
    routes = changing_routes()
    assert (ROUTE_TOOLS.keys() | NO_TOOL.keys()) <= routes
