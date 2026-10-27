"""The weekly run: Chef learns from the week, then plans the next one on its own.

Railway runs `python -m chef.run` every hour (the omlete-chef service in
railway.json). Each run checks the household's chosen day and hour in UK time,
so a change in Settings needs no redeploy and the clocks going forward or back
moves nothing. A run that finds the plan already there does nothing, and one
that fails is tried again the next hour, for a few hours. The plan only
proposes: it waits on Home as a card until they tap (docs/PRD_CHEF.md).

`python -m chef.run --now` plans the coming week whatever the time.
"""

import argparse
import asyncio
import logging
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from chef import memory as chef_memory
from chef import week
from data_models import UserSettingsDocument, WeekPlanDocument
from lib.db import get_motor_client, init_documents
from services import settings

logger = logging.getLogger("chef.run")

UK = ZoneInfo("Europe/London")
# How long after the chosen hour a run still plans, so a failed run is tried
# again, but a time changed in Settings to one just past doesn't plan at once.
CATCH_UP = timedelta(hours=4)


def due(now: datetime, s: UserSettingsDocument) -> date | None:
    """The week to plan if `now` (UK time) is within the catch-up after the chosen hour; None otherwise."""
    days_since = (now.weekday() - s.weekly_plan_weekday) % 7
    chosen = (now - timedelta(days=days_since)).replace(
        hour=s.weekly_plan_hour, minute=0, second=0, microsecond=0
    )
    if chosen > now:
        chosen -= timedelta(days=7)
    if not s.weekly_plan or now - chosen >= CATCH_UP:
        return None
    return week.next_week_from(chosen.date(), s.week_start_weekday)


async def weekly(now: datetime, force: bool = False) -> WeekPlanDocument | None:
    """Distil, then plan the coming week, when it's time and no plan for it exists yet."""
    s = await settings.get_or_create()
    week_of = week.next_week_from(now.date(), s.week_start_weekday) if force else due(now, s)
    if week_of is None:
        return None
    # Made, skipped or waiting: they've seen this week already.
    if await WeekPlanDocument.find_one(WeekPlanDocument.week_of == week_of):
        logger.info("The week of %s is already planned", week_of)
        return None
    try:
        await chef_memory.distil()
    except Exception:
        # Planning on last week's preferences beats not planning.
        logger.exception("Distil failed; planning with what Chef already knows")
    plan, _ = await week.plan(week_of=week_of)
    logger.info("Planned the week of %s", week_of)
    return plan


async def main(force: bool) -> None:
    client = get_motor_client()
    try:
        await init_documents(client)
        await weekly(datetime.now(UK).replace(tzinfo=None), force=force)
    finally:
        client.close()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--now", action="store_true", help="plan the coming week whatever the time")
    asyncio.run(main(parser.parse_args().now))
