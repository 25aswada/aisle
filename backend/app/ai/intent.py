"""Turn free-text search queries into a structured item intent."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from functools import lru_cache

from .catalog import CATEGORIES, CATEGORY_BY_SLUG, CategoryDef

# Phrases people type around the item itself. Longest first.
_FILLER_PREFIXES = (
    "where can i find", "where can i get", "where can i buy", "where do i find",
    "where do you keep", "where would i find", "where are the", "where is the",
    "where are", "where is", "where's", "do you have", "do you sell", "do you carry",
    "looking for", "i need", "i want", "need", "find", "get", "buy",
)
_STOPWORDS = {"the", "a", "an", "some", "any", "please", "of", "for", "me", "my", "to"}
_QUANTITY_UNITS = {
    "dozen", "pack", "packs", "bag", "bags", "box", "boxes", "bottle", "bottles", "can",
    "cans", "jar", "jars", "gallon", "gallons", "lb", "lbs", "pound", "pounds", "oz",
    "ounce", "ounces", "carton", "cartons", "loaf", "loaves", "bunch", "bunches", "roll",
    "rolls", "half", "liter", "liters", "case", "cases", "container", "containers",
}
_NUMBER_WORDS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
    "eight": 8, "nine": 9, "ten": 10, "twelve": 12, "a": 1, "an": 1,
}
MODIFIERS = {
    "organic", "fresh", "frozen", "large", "small", "big", "whole", "sliced", "diced",
    "low", "fat", "nonfat", "reduced", "sugar", "free", "gluten", "unsalted", "salted",
    "lean", "boneless", "skinless", "raw", "cooked", "ripe", "local", "vegan", "plain",
    "unsweetened", "sweetened", "extra", "virgin", "light", "dark", "spicy", "mild",
    "generic", "store", "brand", "cheap", "family", "size",
}
# Modifiers that can change the category (frozen peas live in Frozen, not Produce).
_FROZEN_REDIRECT = {"produce-fruit", "produce-veg", "meat", "seafood", "bakery"}


# Plurals whose singular ends in "ie" (cookies -> cookie, not "cooky").
_IE_SINGULARS = {
    "cookie", "brownie", "veggie", "smoothie", "hoagie", "pierogie", "movie", "beanie",
    "calorie", "goalie", "tie", "pie",
}


def singularize(word: str) -> str:
    if word.endswith("s") and word[:-1] in _IE_SINGULARS:
        return word[:-1]
    if len(word) <= 3 or word.endswith(("ss", "us", "is", "ous")):
        return word
    if word.endswith("ies") and len(word) > 4:
        return word[:-3] + "y"
    if word.endswith("oes"):
        return word[:-2]
    if word.endswith(("ches", "shes", "sses", "xes", "zes")):
        return word[:-2]
    if word.endswith("ves") and word not in {"olives", "chives"}:
        return word[:-3] + "f" if word[:-3].endswith("l") else word[:-1]
    if word.endswith("s"):
        return word[:-1]
    return word


def tokenize(text: str) -> list[str]:
    text = text.lower().replace("&", " and ").replace("’", "'")
    text = re.sub(r"'s\b", "", text)
    text = re.sub(r"[^a-z0-9%\s-]", " ", text)
    text = text.replace("-", " ")
    return [t for t in text.split() if t]


def normalize_tokens(text: str) -> tuple[str, ...]:
    return tuple(singularize(t) for t in tokenize(text))


def normalize(text: str) -> str:
    return " ".join(normalize_tokens(text))


@lru_cache(maxsize=1)
def _term_index() -> dict[tuple[str, ...], CategoryDef]:
    index: dict[tuple[str, ...], CategoryDef] = {}
    for category in CATEGORIES:
        for term in category.terms:
            index.setdefault(normalize_tokens(term), category)
    return index


@lru_cache(maxsize=1)
def max_term_length() -> int:
    return max(len(key) for key in _term_index())


def known_phrase(tokens: tuple[str, ...]) -> CategoryDef | None:
    return _term_index().get(tokens)


@dataclass
class CategoryMatch:
    category: CategoryDef
    term: str  # the normalized catalog term that matched


@dataclass
class Intent:
    raw: str
    item: str  # display phrase for the item, e.g. "maple syrup"
    normalized: str  # normalized phrase used for lookups, e.g. "maple syrup"
    modifiers: list[str] = field(default_factory=list)
    quantity: str | None = None
    match: CategoryMatch | None = None


def _strip_filler(text: str) -> str:
    lowered = text.lower().strip()
    for prefix in _FILLER_PREFIXES:
        if lowered.startswith(prefix + " "):
            return text.strip()[len(prefix) + 1:]
    return text


def parse_intent(raw: str) -> Intent:
    """Parse one item query such as "where is the organic maple syrup?"."""
    tokens = tokenize(_strip_filler(raw))
    quantity_parts: list[str] = []
    while tokens and (
        tokens[0].isdigit() or tokens[0] in _QUANTITY_UNITS
        or (tokens[0] in _NUMBER_WORDS and len(tokens) > 1 and tokens[1] in _QUANTITY_UNITS)
        or (tokens[0] == "of" and quantity_parts)
    ):
        quantity_parts.append(tokens.pop(0))
    tokens = [t for t in tokens if t not in _STOPWORDS] or tokens
    normalized = tuple(singularize(t) for t in tokens)
    modifier_flags = [t in MODIFIERS for t in tokens]
    match, window = _match(normalized, [t for t in tokens if t in MODIFIERS])
    # Modifiers inside the matched catalog term ("whole milk", "light bulb") stay
    # part of the item; others ("organic") are reported separately.
    keep = [
        i for i, is_modifier in enumerate(modifier_flags)
        if not is_modifier or tokens[i] == "frozen" or (window is not None and window[0] <= i < window[1])
    ] or list(range(len(tokens)))
    return Intent(
        raw=raw,
        item=" ".join(tokens[i] for i in keep),
        normalized=" ".join(normalized[i] for i in keep),
        modifiers=[t for i, t in enumerate(tokens) if i not in keep],
        quantity=" ".join(t for t in quantity_parts if t != "of") or None,
        match=match,
    )


def match_category(tokens: tuple[str, ...], modifiers: list[str] | None = None) -> CategoryMatch | None:
    return _match(tokens, modifiers or [])[0]


def _match(
    tokens: tuple[str, ...], modifiers: list[str]
) -> tuple[CategoryMatch | None, tuple[int, int] | None]:
    """Longest catalog term contained in the tokens wins; later terms break ties
    because English puts the head noun last ("chocolate milk" is milk)."""
    index = _term_index()
    for size in range(min(max_term_length(), len(tokens)), 0, -1):
        hits = [
            start for start in range(len(tokens) - size + 1)
            if tokens[start:start + size] in index and tokens[start:start + size] != ("frozen",)
        ]
        if hits:
            start = hits[-1]
            window = tokens[start:start + size]
            category = index[window]
            if "frozen" in modifiers and category.slug in _FROZEN_REDIRECT:
                category = CATEGORY_BY_SLUG["frozen"]
            return CategoryMatch(category, " ".join(window)), (start, start + size)
    if "frozen" in modifiers:
        return CategoryMatch(CATEGORY_BY_SLUG["frozen"], "frozen"), None
    return None, None
