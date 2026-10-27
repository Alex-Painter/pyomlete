"""The weekly run: Chef learns from the week, then plans the next one on its own.

The API server keeps it scheduled (`keep_planning`, started in main.py): it
sleeps until the household's chosen day and hour in UK time, plans, and
sleeps until the next week. Changing the time in Settings wakes it to work out
the next run again. A week is planned once: a run that finds a plan for it,
made, skipped or waiting, does nothing. After a restart, or a run that failed,
a run up to a few hours late still happens. The plan only proposes: it waits
on Home as a card until they tap (docs/PRD_CHEF.md).

`python -m chef.run` plans the coming week now, whatever the time.
"""

import asyncio
import logging
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from pymongo.errors import DuplicateKeyError

from chef import memory as chef_memory
from chef import week
from data_models import UserSettingsDocument, WeekPlanDocument
from services import settings

logger = logging.getLogger("chef.run")

UK = ZoneInfo("Europe/London")
# How late a run may still happen, after a restart or a failure. A time
# changed in Settings to one earlier today plans at once only within it.
CATCH_UP = timedelta(hours=4)
RETRY = timedelta(hours=1)


def uk_now() -> datetime:
    """The time in the UK now, without a zone, as the settings are."""
    return datetime.now(UK).replace(tzinfo=None)


def last_chosen(now: datetime, s: UserSettingsDocument) -> datetime:
    """The latest chosen day and hour at or before `now`."""
    days_since = (now.weekday() - s.weekly_plan_weekday) % 7
    chosen = (now - timedelta(days=days_since)).replace(
        hour=s.weekly_plan_hour, minute=0, second=0, microsecond=0
    )
    return chosen - timedelta(days=7) if chosen > now else chosen


def due(now: datetime, s: UserSettingsDocument) -> date | None:
    """The week to plan if `now` is within the catch-up after the chosen hour; None otherwise."""
    chosen = last_chosen(now, s)
    if not s.weekly_plan or now - chosen >= CATCH_UP:
        return None
    return week.next_week_from(chosen.date(), s.week_start_weekday)


def seconds_until(then: datetime) -> float:
    """From now to a UK time, counting a change of the clocks in between."""
    return (then.replace(tzinfo=UK).astimezone(timezone.utc) - datetime.now(timezone.utc)).total_seconds()


async def weekly(now: datetime, force: bool = False) -> WeekPlanDocument | None:
    """Distil, then plan the coming week, when it's time and no plan for it exists yet."""
    s = await settings.get_or_create()
    week_of = week.next_week_from(now.date(), s.week_start_weekday) if force else due(now, s)
    if week_of is None:
        return None
    # Made, skipped or waiting: they've seen this week already.
    if await WeekPlanDocument.find_one(WeekPlanDocument.week_of == week_of):
        return None
    try:
        await chef_memory.distil()
    except Exception:
        # Planning on last week's preferences beats not planning.
        logger.exception("Distil failed; planning with what Chef already knows")
    try:
        plan, _ = await week.plan(week_of=week_of)
    except DuplicateKeyError:
        # Another instance, mid-deploy, planned it first.
        return None
    logger.info("Planned the week of %s", week_of)
    return plan


_changed: asyncio.Event | None = None


def reschedule() -> None:
    """The chosen time changed: work out the next run again."""
    if _changed:
        _changed.set()


async def keep_planning() -> None:
    """Run `weekly` at each chosen time, for as long as the server runs."""
    global _changed
    _changed = asyncio.Event()
    while True:
        _changed.clear()
        wake: datetime | None = None
        try:
            s = await settings.get_or_create()
            now = uk_now()
            await weekly(now)
            if s.weekly_plan:
                wake = last_chosen(now, s) + timedelta(days=7)
        except Exception:
            logger.exception("The weekly run failed; trying again in an hour")
            wake = uk_now() + RETRY
        try:
            timeout = None if wake is None else max(seconds_until(wake), 0)
            await asyncio.wait_for(_changed.wait(), timeout)
        except TimeoutError:
            pass


async def _plan_now() -> None:
    from lib.db import get_motor_client, init_documents

    client = get_motor_client()
    try:
        await init_documents(client)
        await weekly(uk_now(), force=True)
    finally:
        client.close()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(_plan_now())
