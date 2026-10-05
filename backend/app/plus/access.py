"""Who is asking, whether they have Aisle+, and how much AI each person gets a day.

Aisle+ comes from a verified App Store subscription that belongs to an account: the
one it was bought for, or one it was restored to. Signed out, nobody has Aisle+, and
deleting the account ends it. Free shoppers get a few photo searches, follow-ups and
AI-answered searches a day, counted per account when signed in (so reinstalling
doesn't reset them; see auth.accounts for deleting) and otherwise per network. Aisle+
is unlimited within fair use: daily ceilings no real shopper reaches, counted apart
from the free tier. A use is counted before the AI runs, in one atomic step, and
handed back if nothing came of it. Everyone's AI use together has a daily budget in
dollars too (see ai.budget): each use starts the meter that charges its AI calls to it.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timezone

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..ai.budget import budget_spent, start_metering
from ..config import get_settings
from ..limits import bump, day_window
from ..models import PlusEntitlement, UsageCounter, User

log = logging.getLogger(__name__)

PHOTO_SEARCH = "photo_search"
FOLLOW_UP = "follow_up"
# Any search by a signed-in free account (a hard daily limit; Aisle+ isn't counted).
SEARCH = "search"
# A text search answered with the AI's help (its guess, its "where to find it" answer).
AI_SEARCH = "ai_search"
PLUS_PRODUCTS = {"app.shopaisle.plus.yearly", "app.shopaisle.plus.monthly"}

# What each limited feature is called, singular and plural, for "You've used today's…".
_NOUNS = {
    SEARCH: ("search", "searches"),
    PHOTO_SEARCH: ("photo search", "photo searches"),
    FOLLOW_UP: ("follow-up", "follow-ups"),
    AI_SEARCH: ("AI answer", "AI answers"),
}


def upgrade_message(feature: str, limit: int) -> str:
    """E.g. "You've used today's free photo search." or "…today's 5 free searches."""
    one, many = _NOUNS[feature]
    used = f"free {one}" if limit == 1 else f"{limit} free {many}"
    return f"You've used today's {used}. Aisle+ has unlimited."

FAIR_USE = "That's a lot for one day, even with Aisle+. It resets tomorrow."
AI_PAUSED = "Aisle's AI is taking a break for today. Try again tomorrow."


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


def limit_for(feature: str, *, plus: bool = False, signed_in: bool = True) -> int:
    """Uses allowed a day: the free tier's, or Aisle+'s fair-use ceiling."""
    s = get_settings()
    if plus:
        return {PHOTO_SEARCH: s.aisle_plus_photo_searches, FOLLOW_UP: s.aisle_plus_follow_ups,
                AI_SEARCH: s.aisle_plus_ai_searches}[feature]
    if feature == AI_SEARCH:
        return s.aisle_free_ai_searches if signed_in else s.aisle_signed_out_ai_searches
    if feature == SEARCH:
        return s.aisle_free_searches
    return s.aisle_free_photo_searches if feature == PHOTO_SEARCH else s.aisle_free_follow_ups


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
    """One use of a limited feature, already counted. Refund it when the feature gave
    nothing back, so failures don't use up the day's tries. What the AI cost stays
    spent: the budget counts money, not uses."""
    db: Session
    subject: str
    counter: str  # The feature, or "plus:<feature>" for Aisle+'s fair-use count.
    day: str
    counted: bool = True

    def refund(self) -> None:
        if self.counted:
            bump(self.db, self.subject, self.counter, self.day, -1)
            self.counted = False


def reserve_allowance(db: Session, caller: Caller, feature: str) -> Allowance:
    """Counts one use now. Raises 402 when a free shopper is out for today, 429 past
    Aisle+'s fair use, and 503 once everyone's AI budget for the day is spent. The
    request's AI calls are charged to that budget from here on."""
    plus = is_plus(db, caller)
    counter, day = (f"plus:{feature}" if plus else feature), today()
    limit = limit_for(feature, plus=plus, signed_in=caller.user is not None)
    if bump(db, caller.subject, counter, day) > limit:
        bump(db, caller.subject, counter, day, -1)
        if plus:
            raise HTTPException(status_code=429, detail=FAIR_USE)
        raise plus_required(feature, upgrade_message(feature, limit), limit)
    if budget_spent(db):
        bump(db, caller.subject, counter, day, -1)
        log.warning("Today's AI budget for everyone is spent; AI features are paused")
        raise HTTPException(status_code=503, detail=AI_PAUSED)
    start_metering(db)
    return Allowance(db, caller.subject, counter, day)


def search_allowance(db: Session, caller: Caller) -> Allowance | None:
    """Counts one search for a signed-in free account, raising 402 once today's are used.
    None for Aisle+ (unlimited) and signed out (limited by rate and AI answers instead).
    No AI budget check: a search still works on Aisle's own data when the AI is paused."""
    if caller.user is None or is_plus(db, caller):
        return None
    day, limit = today(), limit_for(SEARCH)
    if bump(db, caller.subject, SEARCH, day) > limit:
        bump(db, caller.subject, SEARCH, day, -1)
        raise plus_required(SEARCH, upgrade_message(SEARCH, limit), limit)
    return Allowance(db, caller.subject, SEARCH, day)


def require_follow_up_allowed(db: Session, caller: Caller, messages: list[dict]) -> None:
    """The free plan gets a set number of follow-ups per search. The conversation starts
    with the search and its answer, so earlier follow-ups are the shopper's messages
    between the first one and the newest."""
    allowed = get_settings().aisle_free_follow_ups_per_search
    earlier = sum(1 for m in messages[1:-1] if m.get("role") == "user")
    if earlier >= allowed and not is_plus(db, caller):
        noun = "follow-up" if allowed == 1 else "follow-ups"
        raise plus_required(
            FOLLOW_UP, f"The free plan includes {allowed} {noun} per search. Aisle+ has unlimited.", allowed)


def ai_search_allowance(db: Session, caller: Caller) -> Allowance | None:
    """One AI-answered search, or None when the caller (or everyone) is out for today;
    the search then runs on Aisle's own data and wording instead."""
    try:
        return reserve_allowance(db, caller, AI_SEARCH)
    except HTTPException:
        return None


def require_signed_in(caller: Caller, what: str) -> None:
    if caller.user is None:
        raise HTTPException(status_code=401, detail=f"Sign in to use {what}.")


def require_plus(db: Session, caller: Caller, feature: str, message: str) -> None:
    if not is_plus(db, caller):
        raise plus_required(feature, message)
