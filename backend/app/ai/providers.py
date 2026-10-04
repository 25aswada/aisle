"""AI provider interface. Providers return structured guesses, never prose."""
from __future__ import annotations

import json
import logging
from typing import Protocol

from ..config import get_settings
from .catalog import CATEGORIES, LayoutDef
from .explain import EXPLAIN_SYSTEM_PROMPT, CachedExplainer, Explainer, ExplainFacts, facts_prompt
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

    def __init__(self, api_key: str, model: str, timeout: float, reply_timeout: float | None = None):
        import anthropic  # Imported lazily so the fallback works without the SDK.

        self._client = anthropic.Anthropic(api_key=api_key, timeout=timeout, max_retries=1)
        self._model = model
        # Written replies run longer than structured guesses.
        self._reply_timeout = reply_timeout or timeout

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

    def explain(self, facts: ExplainFacts) -> str | None:
        return self.chat(EXPLAIN_SYSTEM_PROMPT, [{"role": "user", "content": facts_prompt(facts)}])

    def chat(self, system: str, messages: list[dict]) -> str | None:
        response = self._client.messages.create(
            model=self._model,
            max_tokens=1500,
            system=system,
            messages=[{"role": m["role"], "content": _anthropic_content(m)} for m in messages],
            timeout=self._reply_timeout,
        )
        if response.stop_reason in ("refusal", "max_tokens"):
            return None
        return "".join(block.text for block in response.content if block.type == "text").strip() or None


class OpenAILocationModel:
    name = "openai"

    def __init__(self, api_key: str, model: str, timeout: float, reply_timeout: float | None = None):
        import openai  # Imported lazily so the fallback works without the SDK.

        self._client = openai.OpenAI(api_key=api_key, timeout=timeout, max_retries=1)
        self._model = model
        # Written replies run longer than structured guesses.
        self._reply_timeout = reply_timeout or timeout

    def locate(self, intent: Intent, retailer_name: str | None, layout: LayoutDef) -> LocationGuess | None:
        departments = ", ".join(z.name for z in layout.zones)
        prompt = (
            f"Store: {retailer_name or 'unknown retailer'} ({layout.label}).\n"
            f"Departments: {departments}.\n"
            f"Item searched: {intent.raw.strip()}"
        )
        try:
            response = self._client.chat.completions.create(
                model=self._model,
                messages=[
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": prompt},
                ],
                response_format={
                    "type": "json_schema",
                    "json_schema": {"name": "location_guess", "schema": response_schema(layout), "strict": True},
                },
            )
            choice = response.choices[0]
            if choice.finish_reason != "stop" or choice.message.refusal or not choice.message.content:
                return None
            return guess_from_model_output(json.loads(choice.message.content), intent, layout)
        except Exception:  # Provider problems must never break search.
            log.warning("AI provider failed; using deterministic fallback", exc_info=True)
            return None


    def explain(self, facts: ExplainFacts) -> str | None:
        return self.chat(EXPLAIN_SYSTEM_PROMPT, [{"role": "user", "content": facts_prompt(facts)}])

    def chat(self, system: str, messages: list[dict]) -> str | None:
        response = self._client.chat.completions.create(
            model=self._model,
            messages=[
                {"role": "system", "content": system},
                *({"role": m["role"], "content": _openai_content(m)} for m in messages),
            ],
            timeout=self._reply_timeout,
        )
        choice = response.choices[0]
        if choice.finish_reason != "stop" or choice.message.refusal:
            return None
        return (choice.message.content or "").strip() or None


def _media_type(image: str) -> str:
    return "image/png" if image.startswith("iVBOR") else "image/jpeg"


def _anthropic_content(message: dict) -> str | list[dict]:
    """Plain text, or the photo then the text, in Anthropic's message format."""
    if not message.get("image"):
        return message["content"]
    image = {"type": "image", "source": {"type": "base64", "media_type": _media_type(message["image"]),
                                         "data": message["image"]}}
    return [image, {"type": "text", "text": message["content"] or "(photo)"}]


def _openai_content(message: dict) -> str | list[dict]:
    """Plain text, or the text then the photo, in OpenAI's message format."""
    if not message.get("image"):
        return message["content"]
    url = f"data:{_media_type(message['image'])};base64,{message['image']}"
    return [{"type": "text", "text": message["content"] or "(photo)"}, {"type": "image_url", "image_url": {"url": url}}]


DEFAULT_MODELS = {"anthropic": "claude-opus-5-5", "openai": "gpt-6-luna"}
PROVIDERS = {"anthropic": AnthropicLocationModel, "openai": OpenAILocationModel}


def _choose_provider(settings) -> tuple[str, str] | None:
    """(provider name, api key) for the configured provider, or None without a key."""
    keys = {"anthropic": settings.anthropic_api_key, "openai": settings.openai_api_key}
    if settings.aisle_ai_provider != "auto":
        key = keys[settings.aisle_ai_provider]
        return (settings.aisle_ai_provider, key) if key else None
    for name in ("anthropic", "openai"):
        if keys[name]:
            return name, keys[name]
    return None


_cached_model: tuple[tuple, LocationModel | None] | None = None


def get_location_model() -> LocationModel | None:
    """The configured AI model, or None when no key is set."""
    global _cached_model
    settings = get_settings()
    choice = _choose_provider(settings)
    key = (choice, settings.aisle_ai_model, settings.aisle_ai_timeout_seconds)
    if _cached_model is not None and _cached_model[0] == key:
        return _cached_model[1]
    model: LocationModel | None = None
    if choice:
        name, api_key = choice
        try:
            from .cache import CachedLocationModel

            model = CachedLocationModel(PROVIDERS[name](
                api_key, settings.aisle_ai_model or DEFAULT_MODELS[name], settings.aisle_ai_timeout_seconds
            ))
        except ImportError:
            log.warning("%s package not installed; using deterministic fallback", name)
    _cached_model = (key, model)
    return model


_cached_explainer: tuple[tuple, Explainer | None] | None = None


def get_explainer() -> Explainer | None:
    """AI explanations for search results, or None without a key or when turned off."""
    global _cached_explainer
    settings = get_settings()
    choice = _choose_provider(settings) if settings.aisle_ai_explain else None
    key = (choice, settings.aisle_ai_model, settings.aisle_ai_timeout_seconds, settings.aisle_ai_reply_timeout_seconds)
    if _cached_explainer is not None and _cached_explainer[0] == key:
        return _cached_explainer[1]
    explainer: Explainer | None = None
    if choice:
        name, api_key = choice
        try:
            explainer = CachedExplainer(PROVIDERS[name](
                api_key, settings.aisle_ai_model or DEFAULT_MODELS[name], settings.aisle_ai_timeout_seconds,
                settings.aisle_ai_reply_timeout_seconds,
            ))
        except ImportError:
            log.warning("%s package not installed; no AI explanations", name)
    _cached_explainer = (key, explainer)
    return explainer
