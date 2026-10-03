"""AI provider interface. Providers return structured guesses, never prose."""
from __future__ import annotations

import json
import logging
from typing import Protocol

from ..config import get_settings
from .catalog import CATEGORIES, LayoutDef
from .intent import Intent
from .reasoning import (
    LocationGuess,
    category_from_slug,
    clean_neighbors,
    strip_aisle_claims,
)

log = logging.getLogger(__name__)


class LocationModel(Protocol):
    name: str

    def locate(self, intent: Intent, retailer_name: str | None, layout: LayoutDef) -> LocationGuess | None:
        """Return a guess, or None when the provider can't answer (error, refusal, timeout)."""


SYSTEM_PROMPT = """You place grocery and retail items in a store's departments.
You are given the store format and its department list. Choose the department where
the item is most likely shelved, the item's category, up to four items typically
shelved next to it, and whether this kind of store usually carries it.
Never state aisle numbers or shelf numbers. Pick only from the listed departments.
Use "none" when the store format would not stock the item. Use confidence "medium" only
when the placement is conventional for this store format; otherwise "low"."""


def response_schema(layout: LayoutDef) -> dict:
    return {
        "type": "object",
        "properties": {
            "item": {"type": "string"},
            "category": {"type": "string", "enum": [c.slug for c in CATEGORIES] + ["unknown"]},
            "department": {"type": "string", "enum": [z.name for z in layout.zones] + ["none"]},
            "neighbors": {"type": "array", "items": {"type": "string"}},
            "carried": {"type": "string", "enum": ["likely", "unlikely", "unknown"]},
            "confidence": {"type": "string", "enum": ["medium", "low"]},
        },
        "required": ["item", "category", "department", "neighbors", "carried", "confidence"],
        "additionalProperties": False,
    }


def guess_from_model_output(data: dict, intent: Intent, layout: LayoutDef) -> LocationGuess | None:
    """Validate model JSON against the layout. Anything off-list is discarded."""
    zone_names = {z.name for z in layout.zones}
    category = category_from_slug(data.get("category"))
    department = data.get("department")
    department = department if department in zone_names else None
    carried = data.get("carried") if data.get("carried") in {"likely", "unlikely", "unknown"} else "unknown"
    if department is None and category is None:
        return None
    if department is None:
        # Category known but this format doesn't stock it.
        carried = "unlikely" if carried != "likely" else "unknown"
    confidence = "medium" if data.get("confidence") == "medium" and department and carried == "likely" else "low"
    neighbors = data.get("neighbors") if isinstance(data.get("neighbors"), list) else []
    return LocationGuess(
        category=category,
        department=strip_aisle_claims(department or (category.name if category else None)),
        neighbors=clean_neighbors(neighbors, intent),
        confidence=confidence,
        availability=carried,
        source="model",
    )


class AnthropicLocationModel:
    name = "anthropic"

    def __init__(self, api_key: str, model: str, timeout: float):
        import anthropic  # Imported lazily so the fallback works without the SDK.

        self._client = anthropic.Anthropic(api_key=api_key, timeout=timeout, max_retries=1)
        self._model = model

    def locate(self, intent: Intent, retailer_name: str | None, layout: LayoutDef) -> LocationGuess | None:
        departments = ", ".join(z.name for z in layout.zones)
        prompt = (
            f"Store: {retailer_name or 'unknown retailer'} ({layout.label}).\n"
            f"Departments: {departments}.\n"
            f"Item searched: {intent.raw.strip()}"
        )
        try:
            response = self._client.beta.messages.create(
                model=self._model,
                max_tokens=2048,
                system=SYSTEM_PROMPT,
                messages=[{"role": "user", "content": prompt}],
                output_config={
                    "effort": "low",
                    "format": {"type": "json_schema", "schema": response_schema(layout)},
                },
                # Re-run on Anthropic's recommended model if this one declines.
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
            )
            if response.stop_reason in ("refusal", "max_tokens"):
                return None
            text = next(block.text for block in response.content if block.type == "text")
            return guess_from_model_output(json.loads(text), intent, layout)
        except Exception:  # Provider problems must never break search.
            log.warning("AI provider failed; using deterministic fallback", exc_info=True)
            return None


_cached_model: tuple[tuple, LocationModel | None] | None = None


def get_location_model() -> LocationModel | None:
    """The configured AI model, or None when no key is set."""
    global _cached_model
    settings = get_settings()
    key = (settings.anthropic_api_key, settings.aisle_ai_model, settings.aisle_ai_timeout_seconds)
    if _cached_model is not None and _cached_model[0] == key:
        return _cached_model[1]
    model: LocationModel | None = None
    if settings.anthropic_api_key:
        try:
            model = AnthropicLocationModel(
                settings.anthropic_api_key, settings.aisle_ai_model, settings.aisle_ai_timeout_seconds
            )
        except ImportError:
            log.warning("anthropic package not installed; using deterministic fallback")
    _cached_model = (key, model)
    return model
