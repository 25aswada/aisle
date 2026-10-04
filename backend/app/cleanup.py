"""Deletes data Aisle no longer needs, as the privacy policy promises.

    python -m backend.app.cleanup        # once, by hand

On Heroku the web app also runs it every few hours (see main.py).

- Sign-in code records (hashed phone numbers and emails): after 2 days. Rate limits only look back a day.
- Emailed sign-in codes (hashed): after a day; they expire in 10 minutes.
- Used Apple and Google sign-in nonces (hashed): after 2 days; the tokens expire within the hour.
- Usage counters: daily ones after 8 days, hourly fair-use ones after 2 days.
- App usage events: after 180 days. Searches: after 365 days.
"""
from __future__ import annotations

import logging
import threading
import time
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, not_
from sqlalchemy.orm import Session

from .database import get_engine
from .limits import day_window, hour_window
from .models import AnalyticsEvent, CodeRequest, EmailCode, SearchEvent, UsageCounter, UsedSignInNonce

log = logging.getLogger(__name__)

EVERY = timedelta(hours=6)


def clean_up(db: Session, now: datetime | None = None) -> dict[str, int]:
    now = now or datetime.now(timezone.utc)
    deleted = {
        "code_requests": db.execute(delete(CodeRequest).where(CodeRequest.created_at < now - timedelta(days=2))).rowcount,
        "email_codes": db.execute(delete(EmailCode).where(EmailCode.created_at < now - timedelta(days=1))).rowcount,
        "used_nonces": db.execute(delete(UsedSignInNonce).where(
            UsedSignInNonce.created_at < now - timedelta(days=2))).rowcount,
        # Daily windows look like 2026-10-04, hourly ones like 2026100420.
        "usage_counters": (
            db.execute(delete(UsageCounter).where(
                UsageCounter.day.like("%-%"), UsageCounter.day < day_window(now - timedelta(days=8)))).rowcount
            + db.execute(delete(UsageCounter).where(
                not_(UsageCounter.day.like("%-%")), UsageCounter.day < hour_window(now - timedelta(days=2)))).rowcount
        ),
        "analytics_events": db.execute(delete(AnalyticsEvent).where(
            AnalyticsEvent.received_at < now - timedelta(days=180))).rowcount,
        "search_events": db.execute(delete(SearchEvent).where(
            SearchEvent.created_at < now - timedelta(days=365))).rowcount,
    }
    db.commit()
    return deleted


def run_forever() -> None:
    while True:
        try:
            with Session(get_engine()) as db:
                deleted = clean_up(db)
            log.info("Cleaned up old data: %s", deleted)
        except Exception:
            log.exception("Cleanup failed; trying again later")
        time.sleep(EVERY.total_seconds())


def start_in_background() -> None:
    threading.Thread(target=run_forever, name="aisle-cleanup", daemon=True).start()


if __name__ == "__main__":
    with Session(get_engine()) as session:
        print(clean_up(session))
