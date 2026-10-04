"""AI-written "where to find it" explanations for a resolved search.

The model answers the shopper's question in its own words, like a chatbot reply, from
what it knows about the chain. Only real data for the store (its product data, aisle
numbers, shopper reports) goes in with the question; the resolver's layout guesses don't,
since the model would just repeat them. Its reply reaches the app as written; the app
falls back to its own wording only when there is no reply.
"""
from __future__ import annotations

import logging
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass
from typing import Protocol

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class ExplainFacts:
    """What Aisle worked out about the item, sent to the model with the question."""

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
        """The reply to a search, or None when the provider can't answer."""

    def chat(self, system: str, messages: list[dict]) -> str | None:
        """The next assistant turn, or None. `messages` are {"role", "content"} dicts; a
        shopper's message may also carry "image", base64 JPEG or PNG."""


EXPLAIN_SYSTEM_PROMPT = """You are Aisle, a shopping assistant. A shopper is standing inside a store right now
and asks you where to find something. Answer from your own knowledge of the chain, the
way a friend who shops there every week would walk them to it. Be specific and
concrete; vague answers ("check the snack area") are not useful.

Cover these, each as its own short paragraph of one to three sentences:
1. Where to head: point them in a direction as if they're standing inside the door
   ("If you're inside Costco right now, head toward the very back of the warehouse.").
2. Where exactly: the specific spot, e.g. which wall or row, what it sits between, the
   kind of fixture (refrigerated case, pallets, bakery tables, endcap, top shelf). If
   another version of the item lives somewhere else (packaged vs. fresh, frozen vs.
   shelf-stable), say where that one is too, leading with the one most people mean.
3. What to look for: overhead signs, how it's displayed and packaged, brands or store
   brands, pack sizes, anything that makes it easy to spot.
4. Landmarks around it: two or three big, easy-to-see things near that spot (say where
   they are relative to it) so they can get their bearings, like the rotisserie chicken
   ovens, the walk-in produce cooler, the meat cases, the TV wall, the pharmacy or the
   food court.
5. If it's not there: where else it tends to turn up (seasonal aisle, an endcap, another
   department) and who to ask, like someone at the bakery counter.
6. Finish with a one-line route starting "So:", with arrows, e.g.
   "So: **entrance → straight to the back wall → bakery tables by the cakes.**"

Separate the parts with blank lines. Bold the key places and things to look for with
**double asterisks**: short phrases, not whole sentences. No headings, numbers, bullet
points, links or emoji. Describe the store the way shoppers know it, by landmarks;
don't use left or right, since stores are often mirrored. Stores vary, so say "usually"
where it matters.

Sometimes the question comes with notes holding real data for this store: its own
product data, an aisle number, or reports from shoppers who found the item there. When
it does, trust those over your general knowledge, but never talk about the notes. Only
give an aisle number if the notes include one. If the store probably doesn't carry the
item, say so, suggest the closest thing it does carry and where, and who to ask.
"""

FOLLOW_UP_PROMPT = """

This is a follow-up in an ongoing conversation with the shopper, who is still in {store}.
Answer their latest message directly, in the same voice and with the same concrete detail,
using the earlier turns for context ("them" means the item you were just discussing).
- A new item: answer it in the full shape above.
- They can't find it, or they're somewhere else in the store: start from where they are
  now, give the next places to check, what to look for and who to ask.
- A narrower question (price, a brand, whether it's in stock, how to get somewhere): answer
  just that, but still specifically, and only as long as it needs.
If they send a photo, look at it closely: name what's in it, and if they're asking whether
it's the right thing or where it goes, answer from what you can see.
Don't promise stock or prices for this store; say what it usually carries and what it
usually costs if you know."""

FIND_PROMPT = """You read a shopper's conversation with a store assistant. Decide whether their
latest message asks where to find a product in the store that the assistant hasn't
already located for them in this conversation: a new item ("where are the protein
shakes?", "what about milk"), or a photo of something they want to find.
If it does, reply with only a short search phrase for that product, 1 to 5 words, the way
they'd type it into a store's search (e.g. "protein shakes", "oat milk"). No quotes or
punctuation.
If it doesn't (small talk, a question about price, brands or the item already discussed,
"I don't see them", thanks), reply NONE."""

IDENTIFY_PROMPT = """A shopper took a photo of something they want to find in a store. Reply with
only a short search phrase for the product, 1 to 5 words, the way they'd type it into a
store's search: the kind of product, plus the brand or variety only when it's clearly
visible and matters (e.g. "chocolate chip cookies", "Kirkland paper towels", "oat milk").
Use what they wrote with the photo to decide which item they mean. No quotes, no
punctuation, nothing else. If there's no product in the photo, reply NONE."""


def follow_up_system_prompt(store: str) -> str:
    return EXPLAIN_SYSTEM_PROMPT + FOLLOW_UP_PROMPT.format(store=store)


# Placements that are real data for this store. Anything else (the chain's typical layout,
# a model estimate) is a guess the model would only parrot, so it answers from its own
# knowledge of the chain instead.
STORE_DATA_SOURCES = {"database", "observations", "store_layout"}


def facts_prompt(facts: ExplainFacts) -> str:
    store = facts.store_name or facts.retailer or "this store"
    question = f"Where can I find {facts.item} at {store}?"
    if facts.modifiers:
        question += f" (I'm looking for: {', '.join(facts.modifiers)}.)"
    has_store_data = facts.source in STORE_DATA_SOURCES or facts.aisle or facts.found_reports
    if not has_store_data:
        return question
    lines = [question, "", "Aisle's notes:"]
    if facts.department:
        lines.append(f"Department: {facts.department}")
    if facts.aisle:
        lines.append(f"Aisle: {facts.aisle}")
    if facts.section:
        lines.append(f"Section: {facts.section}")
    if facts.neighbors:
        lines.append(f"Shelved near: {', '.join(facts.neighbors)}")
    lines.append(f"Where this comes from: {SOURCE_WORDS.get(facts.source, facts.source)}")
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


def validate(text: str | None, facts: ExplainFacts | None) -> str | None:
    """The model's reply as written, trimmed; None only when it's empty."""
    text = (text or "").strip()
    return text or None


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
    """In-process TTL cache so repeated searches don't re-call the model.

    Follow-up chat is passed straight through: each conversation is different.
    """

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

    def chat(self, system: str, messages: list[dict]) -> str | None:
        return self._explainer.chat(system, messages)


def explain_safely(explainer: Explainer | None, facts: ExplainFacts) -> str | None:
    """Validated explanation, or None. Provider problems never break search."""
    if explainer is None:
        return None
    try:
        return validate(explainer.explain(facts), facts)
    except Exception:
        log.warning("AI explanation failed; app will use its own wording", exc_info=True)
        return None


def chat_safely(explainer: Explainer | None, system: str, messages: list[dict]) -> str | None:
    """The model's next turn, or None. Provider problems never surface as errors."""
    if explainer is None:
        return None
    try:
        return validate(explainer.chat(system, messages), None)
    except Exception:
        log.warning("AI follow-up failed", exc_info=True)
        return None


def identify_safely(explainer: Explainer | None, image: str, note: str | None) -> str | None:
    """A short search phrase for the product in a photo, or None."""
    if explainer is None:
        return None
    message = {"role": "user", "content": note or "What is this?", "image": image}
    try:
        return clean_item_phrase(explainer.chat(IDENTIFY_PROMPT, [message]))
    except Exception:
        log.warning("AI photo identification failed", exc_info=True)
        return None


def clean_item_phrase(text: str | None) -> str | None:
    """The model's phrase as a search query: one line, no quotes or end punctuation."""
    phrase = " ".join((text or "").split()).strip(" \"'“”‘’.!?")
    if not phrase or phrase.upper() == "NONE" or len(phrase) > 60:
        return None
    return phrase


def wanted_item_safely(explainer: Explainer | None, messages: list[dict]) -> str | None:
    """The product a follow-up asks to find, as a search phrase; None for conversation."""
    if explainer is None:
        return None
    try:
        return clean_item_phrase(explainer.chat(FIND_PROMPT, messages))
    except Exception:
        log.warning("AI follow-up classification failed", exc_info=True)
        return None
