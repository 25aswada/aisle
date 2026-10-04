"""Who's calling (by a client IP that can't be faked) and atomic counters for limits.

Counters live in usage_counters, keyed by subject, feature and window: a UTC day
("2026-10-04") for the free tier, an hour ("2026100420") for fair-use rate limits.
`bump` adds and reads a count in one statement, so parallel requests can't all slip
under a limit.
"""
from __future__ import annotations

from contextvars import ContextVar
from datetime import datetime, timezone

from fastapi import HTTPException, Request
from sqlalchemy.dialects.postgresql import insert as postgres_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.orm import Session

from .models import UsageCounter

# The calling client's IP, set for each request by the app's middleware.
request_ip: ContextVar[str | None] = ContextVar("request_ip", default=None)


def client_ip(request: Request) -> str | None:
    """The client's IP. Heroku's router appends the address it saw to X-Forwarded-For,
    so only the last entry is trustworthy; anything before it came from the client."""
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[-1].strip()[:45] or None
    return request.client.host if request.client else None


def day_window(now: datetime | None = None) -> str:
    return (now or datetime.now(timezone.utc)).date().isoformat()


def hour_window(now: datetime | None = None) -> str:
    return (now or datetime.now(timezone.utc)).strftime("%Y%m%d%H")


def bump(db: Session, subject: str, feature: str, window: str, by: int = 1) -> int:
    """Adds `by` to a counter and returns its new value, atomically, and commits."""
    insert = postgres_insert if db.get_bind().dialect.name == "postgresql" else sqlite_insert
    statement = insert(UsageCounter).values(subject=subject[:80], feature=feature, day=window, count=by)
    statement = statement.on_conflict_do_update(
        index_elements=["subject", "feature", "day"], set_={"count": UsageCounter.count + by},
    ).returning(UsageCounter.count)
    count = db.execute(statement).scalar_one()
    db.commit()
    return count


def rate_limit(db: Session, subject: str, name: str, per_hour: int,
               message: str = "That's a lot of requests. Try again in a little while.") -> None:
    """Fair use: raises 429 once `subject` has made `per_hour` calls to `name` this hour."""
    if bump(db, subject, f"rl:{name}", hour_window()) > per_hour:
        raise HTTPException(status_code=429, detail=message)
