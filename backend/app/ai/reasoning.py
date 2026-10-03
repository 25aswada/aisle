"""Generic location reasoning shared by the deterministic fallback and AI providers."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Literal

from .catalog import CATEGORY_BY_SLUG, CategoryDef, LayoutDef
from .intent import Intent, normalize

Confidence = Literal["high", "medium", "low"]
Availability = Literal["likely", "unlikely", "unknown"]

MAX_NEIGHBORS = 4
_AISLE_CLAIM = re.compile(r"\b(aisle|isle|row|bay)\s*#?\s*\d+", re.IGNORECASE)


@dataclass
class LocationGuess:
    """A generic, store-format-level guess. Never carries an aisle number."""
    category: CategoryDef | None
    department: str | None
    neighbors: list[str] = field(default_factory=list)
    confidence: Confidence = "low"
    availability: Availability = "unknown"
    source: Literal["model", "fallback"] = "fallback"


def clean_neighbors(neighbors: list[str], item: Intent | str) -> list[str]:
    """Drop the item itself, duplicates, empty values, and anything aisle-like."""
    item_norm = normalize(item.item if isinstance(item, Intent) else item)
    seen: set[str] = set()
    cleaned: list[str] = []
    for neighbor in neighbors:
        text = " ".join(str(neighbor).split())[:40]
        key = normalize(text)
        if not text or key in seen or key == item_norm or _AISLE_CLAIM.search(text):
            continue
        seen.add(key)
        cleaned.append(text)
    return cleaned[:MAX_NEIGHBORS]


def strip_aisle_claims(text: str | None) -> str | None:
    """Department names from a model must not smuggle in aisle numbers."""
    if not text:
        return None
    cleaned = _AISLE_CLAIM.sub("", text).strip(" ,-/")
    return cleaned or None


def fallback_guess(intent: Intent, layout: LayoutDef) -> LocationGuess:
    """Deterministic reasoning from the catalog and the store-format layout."""
    if intent.match is None:
        return LocationGuess(category=None, department=None, confidence="low")
    return guess_for_category(intent.match.category, intent, layout, source="fallback")


def guess_for_category(
    category: CategoryDef, intent: Intent, layout: LayoutDef, source: Literal["model", "fallback"]
) -> LocationGuess:
    zone = layout.zone_for(category.slug)
    neighbors = clean_neighbors(list(category.neighbors), intent)
    if zone is None:
        # This store format usually doesn't stock the category.
        return LocationGuess(
            category=category, department=category.name, neighbors=neighbors,
            confidence="low", availability="unlikely", source=source,
        )
    return LocationGuess(
        category=category, department=zone.name, neighbors=neighbors,
        confidence="medium", availability="likely", source=source,
    )


def category_from_slug(slug: str | None) -> CategoryDef | None:
    return CATEGORY_BY_SLUG.get(slug or "")
