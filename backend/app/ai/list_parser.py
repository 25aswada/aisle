"""Split free text into shopping list items.

"milk eggs bananas toothpaste"   -> milk | eggs | bananas | toothpaste
"2 milk, maple syrup\nhalf and half" -> 2 milk | maple syrup | half and half

When the text has explicit separators (newlines, commas, semicolons, bullets, or
" and " outside known phrases), each piece is one item. Without separators the
words are segmented by known catalog phrases, longest first; consecutive unknown
words stay together as one item.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from .catalog import CATEGORIES, CategoryDef
from .intent import MODIFIERS, NUMBER_WORDS, QUANTITY_UNITS, known_phrase, max_term_length, parse_intent, singularize, tokenize

MAX_ITEMS = 100
_SEPARATORS = re.compile(r"[\n,;•·]+|(?:^|\s)[-*](?=\s)|\s+and\s+|\s+&\s+", re.IGNORECASE)
_NUMBER = re.compile(r"^\d+(?:\.\d+)?x?$")


@dataclass
class ListItem:
    text: str
    quantity: str | None
    category: CategoryDef | None


def _protected_and_phrases() -> list[str]:
    phrases = [t for c in CATEGORIES for t in c.terms if " and " in t]
    return sorted(phrases, key=len, reverse=True)


_AND_PHRASES = _protected_and_phrases()


def _split_explicit(text: str) -> list[str]:
    # Keep catalog phrases like "half and half" whole before splitting on "and".
    protected = text
    for index, phrase in enumerate(_AND_PHRASES):
        protected = re.sub(rf"\b{re.escape(phrase)}\b", f"\x00{index}\x00", protected, flags=re.IGNORECASE)
    pieces = _SEPARATORS.split(protected)
    restore = lambda piece: re.sub(r"\x00(\d+)\x00", lambda m: _AND_PHRASES[int(m.group(1))], piece)
    return [restore(p).strip() for p in pieces if p and p.strip()]


def _has_separators(text: str) -> bool:
    return len(_split_explicit(text)) > 1


def _segment(text: str) -> list[str]:
    """Split a separator-free run of words into items by known phrases."""
    tokens = tokenize(text)
    normalized = [singularize(t) for t in tokens]
    items: list[list[str]] = []
    prefix: list[str] = []  # quantities and modifiers waiting for their item
    unknown: list[str] = []

    def flush_unknown():
        nonlocal prefix
        if unknown:
            items.append(prefix + unknown)
            unknown.clear()
            prefix = []

    i = 0
    while i < len(tokens):
        size = next(
            (s for s in range(min(max_term_length(), len(tokens) - i), 0, -1)
             if known_phrase(tuple(normalized[i:i + s])) is not None),
            0,
        )
        if size:
            flush_unknown()
            items.append(prefix + tokens[i:i + size])
            prefix = []
            i += size
        elif (
            _NUMBER.match(tokens[i]) or tokens[i] in MODIFIERS or tokens[i] in QUANTITY_UNITS
            or tokens[i] in NUMBER_WORDS or (tokens[i] == "of" and prefix)
        ):
            flush_unknown()
            prefix.append(tokens[i])
            i += 1
        else:
            unknown.append(tokens[i])
            i += 1
    flush_unknown()
    if prefix:
        if items:
            items[-1].extend(prefix)
        else:
            items.append(prefix)
    return [" ".join(words) for words in items]


def parse_list(text: str) -> list[ListItem]:
    pieces = _split_explicit(text) if _has_separators(text) else _segment(text)
    items: list[ListItem] = []
    for piece in pieces:
        intent = parse_intent(piece)
        display = " ".join(intent.modifiers + [intent.item]).strip() if intent.modifiers else intent.item
        if not display:
            continue
        items.append(ListItem(
            text=display,
            quantity=intent.quantity,
            category=intent.match.category if intent.match else None,
        ))
        if len(items) == MAX_ITEMS:
            break
    return items
