"""Tag every recipe that has no tags yet.

    cd server && .venv/bin/python scripts/backfill_tags.py [--force]

Runs in batches of 20. A recipe with tags is skipped unless --force, so a
second run, or a rerun after a crash, only does what is left.
"""

import argparse
import asyncio
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from anthropic import AsyncAnthropic  # noqa: E402

from data_models import RecipeDocument  # noqa: E402
from recipe_tagger import tag_and_store  # noqa: E402

BATCH = 20


async def backfill(client: AsyncAnthropic, force: bool = False) -> tuple[int, int, int]:
    """Tag what needs it. Returns (tagged, already tagged, failed)."""
    query = {} if force else {"tags": None}
    todo = [r.id for r in await RecipeDocument.find(query).to_list()]
    already = 0 if force else await RecipeDocument.find({"tags": {"$ne": None}}).count()
    tagged = failed = 0
    for start in range(0, len(todo), BATCH):
        results = await asyncio.gather(
            *(tag_and_store(rid, client) for rid in todo[start:start + BATCH]),
            return_exceptions=True,
        )
        for ok in results:
            if ok is True:
                tagged += 1
            else:
                failed += 1
                if isinstance(ok, BaseException):
                    logging.warning("tagging failed: %s", ok)
        print(f"{tagged + failed} of {len(todo)} done", flush=True)
    return tagged, already, failed


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--force", action="store_true", help="re-tag recipes that already have tags")
    args = parser.parse_args()

    from lib.db import get_motor_client, init_documents

    logging.basicConfig(level=logging.INFO)
    client = get_motor_client()
    await init_documents(client)
    tagged, already, failed = await backfill(AsyncAnthropic(), args.force)
    print(f"{tagged} tagged, {already} already tagged, {failed} failed")
    client.close()


if __name__ == "__main__":
    asyncio.run(main())
