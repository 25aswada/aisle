"""What the AI costs, and everyone's daily budget for it.

Every provider call is priced from the tokens it used (the provider's own count when
the response has one, an estimate otherwise) and added to today's spend, kept in
usage_counters in millionths of a dollar. Once the day's spend reaches
AISLE_AI_BUDGET_USD_PER_DAY, AI features pause until tomorrow (see plus.access).

Calls are charged to the request that made them: reserving an allowance starts the
meter for the request. A call made with no meter running (evaluate.py, unit tests)
is priced but not recorded.
"""
from __future__ import annotations

import logging
import math
from contextvars import ContextVar

from sqlalchemy import select
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session

from ..config import get_settings
from ..limits import bump, day_window
from ..models import UsageCounter

log = logging.getLogger(__name__)

# Everyone's AI use today, in millionths of a dollar. Postgres integers top out a little
# over $2,000 of spend a day, far past any sensible budget.
EVERYONE = "everyone"
AI_SPEND = "ai_spend_microusd"
MICRO = 1_000_000

# US dollars per million tokens: (input, output). A model matches a name when it is that
# name or starts with it plus "-" (dated names like "gpt-5-2025-08-07"); the longest match
# wins. Check these against the providers' price pages when changing models.
PRICES: dict[str, tuple[float, float]] = {
    "claude-fable": (10.0, 50.0),
    "claude-mythos": (10.0, 50.0),
    "claude-opus-5-5": (4.0, 20.0),
    "claude-opus-5": (5.0, 25.0),
    "claude-opus-4-8": (5.0, 25.0),
    "claude-opus-4-7": (5.0, 25.0),
    "claude-opus-4-6": (5.0, 25.0),
    "claude-opus-4-5": (5.0, 25.0),
    "claude-sonnet-5": (2.0, 10.0),
    "claude-sonnet-4": (3.0, 15.0),
    "claude-haiku-4-5": (1.0, 5.0),
    "gpt-6-luna": (0.10, 0.50),
    "gpt-5": (1.25, 10.0),
    "gpt-5-mini": (0.25, 2.0),
    "gpt-5-nano": (0.05, 0.40),
    "gpt-4.1": (2.0, 8.0),
    "gpt-4.1-mini": (0.40, 1.60),
    "gpt-4o": (2.50, 10.0),
    "gpt-4o-mini": (0.15, 0.60),
}
# Any other model is priced like the most expensive ones, so an unknown price pauses
# the AI early rather than late.
UNKNOWN_PRICE = (15.0, 75.0)

# Estimates, for when a response doesn't say what it used: about four characters of
# text to a token, and a phone photo as a large image.
CHARS_PER_TOKEN = 4
IMAGE_TOKENS = 2000

# Where this request's AI calls are charged: the database the request uses.
_meter: ContextVar[Engine | None] = ContextVar("ai_meter", default=None)


def price_for(model: str | None) -> tuple[float, float]:
    name = (model or "").lower()
    matches = [key for key in PRICES if name == key or name.startswith(key + "-")]
    return PRICES[max(matches, key=len)] if matches else UNKNOWN_PRICE


def cost_usd(model: str | None, input_tokens: int, output_tokens: int) -> float:
    input_price, output_price = price_for(model)
    return (max(input_tokens, 0) * input_price + max(output_tokens, 0) * output_price) / 1_000_000


def estimate_tokens(text: str = "", images: int = 0) -> int:
    """Rough tokens for text and photos, when the provider doesn't report them."""
    return math.ceil(len(text) / CHARS_PER_TOKEN) + images * IMAGE_TOKENS


def estimate_prompt_tokens(system: str, messages: list[dict]) -> int:
    """Rough tokens for a conversation sent to the model. A photo counts as an image, not
    as the characters of its base64."""
    text = system + "".join(m.get("content") or "" for m in messages)
    return estimate_tokens(text, images=sum(1 for m in messages if m.get("image")))


def start_metering(db: Session) -> None:
    """Charges the rest of this request's AI calls to today's budget, in `db`'s database."""
    _meter.set(db.get_bind())


def charge(model: str | None, input_tokens: int, output_tokens: int) -> float:
    """Adds one provider call to today's spend, and returns what it cost in dollars.
    Uses its own session, so calls on other threads (follow-ups) can charge too."""
    cost = cost_usd(model, input_tokens, output_tokens)
    log.info("AI call on %s: %d tokens in, %d out, $%.4f", model, input_tokens, output_tokens, cost)
    engine = _meter.get()
    if engine is not None and cost > 0:
        try:
            with Session(engine) as db:
                bump(db, EVERYONE, AI_SPEND, day_window(), math.ceil(cost * MICRO))
        except Exception:  # Bookkeeping never breaks an answer.
            log.warning("Couldn't record AI spend", exc_info=True)
    return cost


def spent_today(db: Session) -> float:
    """Everyone's AI spend so far today, in dollars."""
    counter = db.scalar(select(UsageCounter).where(
        UsageCounter.subject == EVERYONE, UsageCounter.feature == AI_SPEND, UsageCounter.day == day_window()))
    return (counter.count if counter else 0) / MICRO


def budget_spent(db: Session) -> bool:
    """Whether today's AI budget is used up. A budget of 0 turns the AI off."""
    return spent_today(db) >= get_settings().aisle_ai_budget_usd_per_day
