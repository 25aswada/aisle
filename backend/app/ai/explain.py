"""AI-written "where to find it" explanations for a resolved search.

The resolver decides *where* an item is; the model only explains that answer in
plain words. It is given the resolved facts and nothing else, and its text is
checked before it reaches the app: an explanation that names an aisle number the
facts don't contain is discarded, and the app falls back to its own wording.
"""
from __future__ import annotations

import logging
import re
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass
from typing import Protocol

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class ExplainFacts:
    """Everything the model may say. Nothing outside this goes into the prompt."""

    item: str
    retailer: str | None
    store_name: str | None
    department: str | None
    aisle: str | None
    section: str | None
    category: str | None
    neighbors: tuple[str, ...]
    confidence: str
    availability: str
    source: str
    modifiers: tuple[str, ...] = ()
    found_reports: int = 0
    not_here_reports: int = 0
    # Rough spot on the floor plan ("toward the back left"), from approximate layout data.
    position: str | None = None
    layout_is_template: bool = True


class Explainer(Protocol):
    def explain(self, facts: ExplainFacts) -> str | None:
        """Two or three sentences, or None when the provider can't answer."""


EXPLAIN_SYSTEM_PROMPT = """You are Aisle, a friendly assistant that helps a shopper find an item
inside one specific store. Using ONLY the facts provided, explain in 2 or 3 short sentences
how to find the item: the department, any aisle or section given, what it's shelved with
or next to, and roughly where that department is in the store when a position is given.
Rules:
- Name the store (the retailer) naturally, e.g. "At Costco, ...".
- Never mention an aisle number, section, or department that is not in the facts.
- If no aisle is given, don't say "aisle"; describe the department and its neighbours.
- If the position comes from a typical layout, say "usually" or "typically", not "exactly".
- Match the confidence: for low confidence or an AI estimate, say it's a best guess and
  suggest asking an employee if it isn't there.
- If availability is "unlikely", say this store typically doesn't carry it, and suggest
  asking an employee; don't send them to a department that isn't given.
- If the shopper asked for something specific (e.g. organic, a brand, a size), mention it,
  e.g. "check the labels for organic"; never claim the store has that variety.
- You may wrap the single most important place (the aisle, or else the department) in
  **double asterisks**. No other formatting, no lists, no emoji."""


def facts_prompt(facts: ExplainFacts) -> str:
    lines = [
        f"Item: {facts.item}",
        f"Store: {facts.retailer or 'unknown'}" + (f" ({facts.store_name})" if facts.store_name else ""),
        f"Department: {facts.department or 'unknown'}",
        f"Aisle: {facts.aisle or 'none on file'}",
        f"Section: {facts.section or 'none on file'}",
        f"Category: {facts.category or 'unknown'}",
        f"Nearby items: {', '.join(facts.neighbors) or 'none given'}",
        f"Position in store: {facts.position or 'unknown'}"
        + (" (from a typical layout for this kind of store)" if facts.position and facts.layout_is_template else ""),
        f"Confidence: {facts.confidence}",
        f"Availability at this store: {facts.availability}",
        f"Source of the location: {SOURCE_WORDS.get(facts.source, facts.source)}",
    ]
    if facts.modifiers:
        lines.append(f"Shopper asked for: {', '.join(facts.modifiers)}")
    if facts.found_reports or facts.not_here_reports:
        lines.append(f"Shopper reports: {facts.found_reports} found it there, {facts.not_here_reports} did not")
    return "\n".join(lines)


SOURCE_WORDS = {
    "database": "the store's own product data",
    "observations": "confirmed by other shoppers",
    "store_layout": "this store's verified layout",
    "model": "an AI estimate for this kind of store",
    "fallback": "the typical layout for this kind of store",
}

_AISLE_NUMBER = re.compile(r"\baisles?\s*#?\s*([A-Za-z]?\d+[A-Za-z]?)", re.IGNORECASE)
_DISALLOWED_MARKUP = re.compile(r"[#`>\[\]]|^\s*[-*]\s", re.MULTILINE)


def validate(text: str | None, facts: ExplainFacts) -> str | None:
    """The explanation if it's safe to show, else None.

    Rejects text that names an aisle number other than the one on file, that is
    empty or rambling, or that uses formatting beyond **bold**.
    """
    if not text:
        return None
    text = " ".join(text.split())
    if not 20 <= len(text) <= 600:
        return None
    if _DISALLOWED_MARKUP.search(text) or text.count("**") % 2:
        return None
    allowed = _aisle_tokens(facts.aisle)
    for match in _AISLE_NUMBER.finditer(text):
        if match.group(1).lower() not in allowed:
            return None
    return text


def _aisle_tokens(aisle: str | None) -> set[str]:
    if not aisle:
        return set()
    return {token.lower() for token in re.findall(r"[A-Za-z]?\d+[A-Za-z]?", aisle)}


def position_words(x: float | None, y: float | None) -> str | None:
    """Coarse words for a floor-plan point (x 0..1 left to right, y 0..1 front to back)."""
    if x is None or y is None:
        return None
    depth = "front" if y < 0.34 else "back" if y > 0.66 else "middle"
    side = "left" if x < 0.34 else "right" if x > 0.66 else "center"
    if depth == "middle" and side == "center":
        return "the middle of the store"
    if side == "center":
        return f"toward the {depth} of the store"
    if depth == "middle":
        return f"along the {side} side of the store"
    return f"toward the {depth} {side} of the store"


class CachedExplainer:
    """In-process TTL cache so repeated searches don't re-call the model."""

    def __init__(self, explainer: Explainer, ttl_seconds: float = 6 * 3600, max_entries: int = 2048,
                 clock=time.monotonic):
        self._explainer = explainer
        self._ttl = ttl_seconds
        self._max = max_entries
        self._clock = clock
        self._entries: OrderedDict[ExplainFacts, tuple[float, str]] = OrderedDict()
        self._lock = threading.Lock()

    def explain(self, facts: ExplainFacts) -> str | None:
        now = self._clock()
        with self._lock:
            hit = self._entries.get(facts)
            if hit and now - hit[0] < self._ttl:
                self._entries.move_to_end(facts)
                return hit[1]
        text = validate(self._explainer.explain(facts), facts)
        if text is not None:  # Don't cache failures; the provider may recover.
            with self._lock:
                self._entries[facts] = (now, text)
                self._entries.move_to_end(facts)
                while len(self._entries) > self._max:
                    self._entries.popitem(last=False)
        return text


def explain_safely(explainer: Explainer | None, facts: ExplainFacts) -> str | None:
    """Validated explanation, or None. Provider problems never break search."""
    if explainer is None:
        return None
    try:
        return validate(explainer.explain(facts), facts)
    except Exception:
        log.warning("AI explanation failed; app will use its own wording", exc_info=True)
        return None
