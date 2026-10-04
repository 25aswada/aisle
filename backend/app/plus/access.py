"""Who is asking, whether they have Aisle+, and the free tier's daily limits.

Aisle+ comes from a verified App Store subscription tied to the device that sent it
and, once signed in, to the account. Free shoppers get a few photo searches and
follow-ups a day, counted per account when signed in (so reinstalling doesn't reset
them) and otherwise per device.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone

from fastapi import HTTPException
from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from ..config import get_settings
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
        if self.user is not None:
            return f"user:{self.user.id}"
        if self.device_id:
            return f"device:{self.device_id}"
        return f"ip:{self.ip or 'unknown'}"


def _aware(moment: datetime | None) -> datetime | None:
    return moment.replace(tzinfo=timezone.utc) if moment and moment.tzinfo is None else moment


def active_entitlement(db: Session, caller: Caller, now: datetime | None = None) -> PlusEntitlement | None:
    now = now or datetime.now(timezone.utc)
    owners = []
    if caller.device_id:
        owners.append(PlusEntitlement.device_id == caller.device_id)
    if caller.user is not None:
        owners.append(PlusEntitlement.user_id == caller.user.id)
    if not owners:
        return None
    for entitlement in db.scalars(select(PlusEntitlement).where(or_(*owners), PlusEntitlement.revoked_at.is_(None))):
        expires = _aware(entitlement.expires_at)
        if expires is None or expires > now:
            return entitlement
    return None


def is_plus(db: Session, caller: Caller) -> bool:
    return active_entitlement(db, caller) is not None


def limit_for(feature: str) -> int:
    settings = get_settings()
    return settings.aisle_free_photo_searches if feature == PHOTO_SEARCH else settings.aisle_free_follow_ups


def today() -> str:
    return datetime.now(timezone.utc).date().isoformat()


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


def check_allowance(db: Session, caller: Caller, feature: str) -> bool:
    """Raises 402 when a free shopper is out for today. Returns True for Aisle+ (no counting)."""
    if is_plus(db, caller):
        return True
    limit = limit_for(feature)
    if used_today(db, caller, feature) >= limit:
        raise plus_required(feature, UPGRADE_MESSAGES[feature].format(limit=limit), limit)
    return False


def count_use(db: Session, caller: Caller, feature: str) -> None:
    """Counts one use of a limited feature, once it actually went through."""
    counter = db.scalar(select(UsageCounter).where(
        UsageCounter.subject == caller.subject, UsageCounter.feature == feature, UsageCounter.day == today()))
    if counter is None:
        counter = UsageCounter(subject=caller.subject, feature=feature, day=today(), count=0)
        db.add(counter)
    counter.count += 1
    db.commit()


def require_plus(db: Session, caller: Caller, feature: str, message: str) -> None:
    if not is_plus(db, caller):
        raise plus_required(feature, message)
