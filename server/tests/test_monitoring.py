"""Sentry stays off without a DSN, and the weekly monitor's schedule follows Settings."""

import sentry_sdk

from lib import monitoring


def test_without_a_dsn_nothing_is_set_up(monkeypatch):
    monkeypatch.delenv("SENTRY_DSN", raising=False)
    monitoring.init()
    monitoring.watch_tasks()
    assert not monitoring.enabled()
    assert not sentry_sdk.get_client().is_active()


def test_the_weekly_schedule_counts_days_from_sunday_as_cron_does():
    assert monitoring.weekly_monitor_config(6, 8, 240)["schedule"]["value"] == "0 8 * * 0"
    assert monitoring.weekly_monitor_config(0, 18, 240)["schedule"]["value"] == "0 18 * * 1"
    assert monitoring.weekly_monitor_config(4, 19, 240)["checkin_margin"] == 240
