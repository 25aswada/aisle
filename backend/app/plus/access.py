"""Who is asking, whether they have Aisle+, and the free tier's daily limits.

Aisle+ comes from a verified App Store subscription that belongs to an account: the
one it was bought for, or one it was restored to. Signed out, nobody has Aisle+, and
deleting the account ends it. Free shoppers get a few photo searches and
follow-ups a day, counted per account when signed in (so reinstalling doesn't reset
them) and otherwise per network. A use is counted before the AI runs, in one atomic
step, and handed back if nothing came of it.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import get_settings
from ..limits import bump, day_window
from ..models import PlusEntitlement, UsageCounter, User

PHOTO_SEARCH = "photo_search"
FOLLOW_UP = "follow_up"
PLUS_PRODUCTS = {"app.shopaisle.plus.yearly", "app.shopaisle.plus.monthly"}

UPGRADE_MESSAGES = {
    PHOTO_SEARCH: "You've used today's {limit} free photo searches. Aisle+ has unlimited.",
    FOLLOW_UP: "You've used today's {limit} free follow-ups. Aisle+ has unlimited.",
}


@dataclass(frozen=True)
class Caller:
    user: User | None
    device_id: str | None
    ip: str | None

    @property
    def subject(self) -> str:
        """Who limits apply to: the account, or signed out the network (the device id is
        whatever the client says, so it can't be trusted for limits)."""
        if self.user is not None:
            return f"user:{self.user.id}"
        return f"ip:{self.ip or 'unknown'}"


def _aware(moment: datetime | None) -> datetime | None:
    return moment.replace(tzinfo=timezone.utc) if moment and moment.tzinfo is None else moment


def active_entitlement(db: Session, caller: Caller, now: datetime | None = None) -> PlusEntitlement | None:
    now = now or datetime.now(timezone.utc)
    if caller.user is None:
        return None
    for entitlement in db.scalars(select(PlusEntitlement).where(
            PlusEntitlement.user_id == caller.user.id, PlusEntitlement.revoked_at.is_(None))):
        expires = _aware(entitlement.expires_at)
        # Subscriptions always expire; one without a date isn't trusted.
        if expires is not None and expires > now:
            return entitlement
    return None


def is_plus(db: Session, caller: Caller) -> bool:
    return active_entitlement(db, caller) is not None


def limit_for(feature: str) -> int:
    settings = get_settings()
    return settings.aisle_free_photo_searches if feature == PHOTO_SEARCH else settings.aisle_free_follow_ups


def today() -> str:
    return day_window()


def used_today(db: Session, caller: Caller, feature: str) -> int:
    counter = db.scalar(select(UsageCounter).where(
        UsageCounter.subject == caller.subject, UsageCounter.feature == feature, UsageCounter.day == today()))
    return counter.count if counter else 0


def plus_required(feature: str, message: str, limit: int | None = None) -> HTTPException:
    """402 with what the app needs to open the Aisle+ page and say why."""
    detail = {"code": "plus_required", "feature": feature, "message": message}
    if limit is not None:
        detail["limit"] = limit
    return HTTPException(status_code=402, detail=detail)


@dataclass
class Allowance:
    """One use of a limited feature, already counted (unless it's Aisle+). Refund it when
    the feature gave nothing back, so failures don't use up the day's free tries."""
    db: Session
    caller: Caller
    feature: str
    counted: bool

    @property
    def unlimited(self) -> bool:
        return not self.counted

    def refund(self) -> None:
        if self.counted:
            bump(self.db, self.caller.subject, self.feature, today(), -1)
            self.counted = False


def reserve_allowance(db: Session, caller: Caller, feature: str) -> Allowance:
    """Counts one use now, or raises 402 when a free shopper is out for today."""
    if is_plus(db, caller):
        return Allowance(db, caller, feature, counted=False)
    limit = limit_for(feature)
    if bump(db, caller.subject, feature, today()) > limit:
        bump(db, caller.subject, feature, today(), -1)
        raise plus_required(feature, UPGRADE_MESSAGES[feature].format(limit=limit), limit)
    return Allowance(db, caller, feature, counted=True)


def require_signed_in(caller: Caller, what: str) -> None:
    if caller.user is None:
        raise HTTPException(status_code=401, detail=f"Sign in to use {what}.")


def require_plus(db: Session, caller: Caller, feature: str, message: str) -> None:
    if not is_plus(db, caller):
        raise plus_required(feature, message)
