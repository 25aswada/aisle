"""AI provider interface. Providers return structured guesses, never prose."""
from __future__ import annotations

import json
import logging
from typing import Protocol

from ..config import get_settings
from .budget import charge, estimate_prompt_tokens, estimate_tokens
from .catalog import CATEGORIES, LayoutDef
from .explain import (
    EXPLAIN_SYSTEM_PROMPT, FIND_PROMPT, IDENTIFY_PROMPT, READ_LIST_PROMPT, CachedExplainer, Explainer,
    ExplainFacts, Moderator, facts_prompt,
)
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


# Output caps (max_tokens), per use. Models that think spend part of the cap on it, so
# even one-line answers leave room; what a call actually used is what's charged.
LOCATE_MAX_TOKENS = 1024  # A location guess: a small JSON object.
PHRASE_MAX_TOKENS = 1024  # A search phrase from a photo or a follow-up, or NONE.
LIST_MAX_TOKENS = 2000  # The items on a photographed shopping list.
REPLY_MAX_TOKENS = 2000  # A "where to find it" answer or a follow-up reply.


def max_tokens_for(system: str) -> int:
    """The output cap for a chat call, by what it's for."""
    if system in (IDENTIFY_PROMPT, FIND_PROMPT):
        return PHRASE_MAX_TOKENS
    if system == READ_LIST_PROMPT:
        return LIST_MAX_TOKENS
    return REPLY_MAX_TOKENS


class MeteredCalls:
    """Sends provider calls and charges each one to today's AI budget: by the tokens the
    response reports, or estimated from the prompt and reply when it reports none. A call
    that times out may still have run and been billed, so it's charged its full cap."""

    name: str
    _model: str
    _cap_param: str  # What the provider calls max_tokens.
    _timeout_error: type[Exception] = TimeoutError

    def _send(self, create, prompt_tokens: int, max_tokens: int, **request):
        try:
            response = create(**{self._cap_param: max_tokens}, **request)
        except self._timeout_error:
            charge(self._model, prompt_tokens, max_tokens)
            raise
        used = self._usage(response)
        model = getattr(response, "model", None)
        if used is None:
            used = (prompt_tokens, estimate_tokens(self._reply_text(response)))
        charge(model if isinstance(model, str) and model else self._model, *used)
        return response

    def _usage(self, response) -> tuple[int, int] | None:
        """(input tokens, output tokens) as the response reports them, or None."""
        raise NotImplementedError

    def _reply_text(self, response) -> str:
        raise NotImplementedError


def _count(usage, *fields: str) -> int | None:
    """The sum of token counts on a usage object, or None when it lacks the first."""
    values = [getattr(usage, field, None) for field in fields]
    if not isinstance(values[0], int):
        return None
    return sum(value for value in values if isinstance(value, int))


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


class AnthropicLocationModel(MeteredCalls):
    name = "anthropic"
    _cap_param = "max_tokens"

    def __init__(self, api_key: str, model: str, timeout: float, reply_timeout: float | None = None,
                 explain_timeout: float | None = None):
        import anthropic  # Imported lazily so the fallback works without the SDK.

        self._client = anthropic.Anthropic(api_key=api_key, timeout=timeout, max_retries=0)
        self._timeout_error = anthropic.APITimeoutError
        self._model = model
        # Written replies run longer than structured guesses. No retries: a retry doubles
        # the wait, and Heroku ends any request after 30 seconds.
        self._reply_timeout = reply_timeout or timeout
        self._explain_timeout = explain_timeout or self._reply_timeout

    def locate(self, intent: Intent, retailer_name: str | None, layout: LayoutDef) -> LocationGuess | None:
        departments = ", ".join(z.name for z in layout.zones)
        prompt = (
            f"Store: {retailer_name or 'unknown retailer'} ({layout.label}).\n"
            f"Departments: {departments}.\n"
            f"Item searched: {intent.phrase}"
        )
        schema = response_schema(layout)
        try:
            response = self._send(
                self._client.beta.messages.create, estimate_tokens(SYSTEM_PROMPT + prompt + json.dumps(schema)),
                LOCATE_MAX_TOKENS,
                model=self._model,
                system=SYSTEM_PROMPT,
                messages=[{"role": "user", "content": prompt}],
                output_config={
                    "effort": "low",
                    "format": {"type": "json_schema", "schema": schema},
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
        return self.chat(EXPLAIN_SYSTEM_PROMPT, [{"role": "user", "content": facts_prompt(facts)}],
                         timeout=self._explain_timeout)

    def chat(self, system: str, messages: list[dict], timeout: float | None = None) -> str | None:
        response = self._send(
            self._client.messages.create, estimate_prompt_tokens(system, messages), max_tokens_for(system),
            model=self._model,
            system=system,
            messages=[{"role": m["role"], "content": _anthropic_content(m)} for m in messages],
            timeout=timeout or self._reply_timeout,
        )
        if response.stop_reason in ("refusal", "max_tokens"):
            return None
        return "".join(block.text for block in response.content if block.type == "text").strip() or None

    def _usage(self, response) -> tuple[int, int] | None:
        usage = getattr(response, "usage", None)
        tokens_in = _count(usage, "input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
        tokens_out = _count(usage, "output_tokens")
        return None if tokens_in is None or tokens_out is None else (tokens_in, tokens_out)

    def _reply_text(self, response) -> str:
        return "".join(getattr(block, "text", None) or "" for block in getattr(response, "content", None) or [])


class OpenAILocationModel(MeteredCalls):
    name = "openai"
    # max_tokens is deprecated, and reasoning models refuse it.
    _cap_param = "max_completion_tokens"

    def __init__(self, api_key: str, model: str, timeout: float, reply_timeout: float | None = None,
                 explain_timeout: float | None = None):
        import openai  # Imported lazily so the fallback works without the SDK.

        self._client = openai.OpenAI(api_key=api_key, timeout=timeout, max_retries=0)
        self._timeout_error = openai.APITimeoutError
        self._model = model
        # Written replies run longer than structured guesses. No retries: a retry doubles
        # the wait, and Heroku ends any request after 30 seconds.
        self._reply_timeout = reply_timeout or timeout
        self._explain_timeout = explain_timeout or self._reply_timeout

    def locate(self, intent: Intent, retailer_name: str | None, layout: LayoutDef) -> LocationGuess | None:
        departments = ", ".join(z.name for z in layout.zones)
        prompt = (
            f"Store: {retailer_name or 'unknown retailer'} ({layout.label}).\n"
            f"Departments: {departments}.\n"
            f"Item searched: {intent.phrase}"
        )
        schema = response_schema(layout)
        try:
            response = self._send(
                self._client.chat.completions.create, estimate_tokens(SYSTEM_PROMPT + prompt + json.dumps(schema)),
                LOCATE_MAX_TOKENS,
                model=self._model,
                messages=[
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": prompt},
                ],
                response_format={
                    "type": "json_schema",
                    "json_schema": {"name": "location_guess", "schema": schema, "strict": True},
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
        return self.chat(EXPLAIN_SYSTEM_PROMPT, [{"role": "user", "content": facts_prompt(facts)}],
                         timeout=self._explain_timeout)

    def chat(self, system: str, messages: list[dict], timeout: float | None = None) -> str | None:
        response = self._send(
            self._client.chat.completions.create, estimate_prompt_tokens(system, messages), max_tokens_for(system),
            model=self._model,
            messages=[
                {"role": "system", "content": system},
                *({"role": m["role"], "content": _openai_content(m)} for m in messages),
            ],
            timeout=timeout or self._reply_timeout,
        )
        choice = response.choices[0]
        if choice.finish_reason != "stop" or choice.message.refusal:
            return None
        return (choice.message.content or "").strip() or None

    def _usage(self, response) -> tuple[int, int] | None:
        usage = getattr(response, "usage", None)
        tokens_in, tokens_out = _count(usage, "prompt_tokens"), _count(usage, "completion_tokens")
        return None if tokens_in is None or tokens_out is None else (tokens_in, tokens_out)

    def _reply_text(self, response) -> str:
        choices = getattr(response, "choices", None) or []
        message = getattr(choices[0], "message", None) if choices else None
        return getattr(message, "content", None) or ""


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
    key = (choice, settings.aisle_ai_model, settings.aisle_ai_timeout_seconds, settings.aisle_ai_reply_timeout_seconds,
           settings.aisle_ai_explain_timeout_seconds)
    if _cached_explainer is not None and _cached_explainer[0] == key:
        return _cached_explainer[1]
    explainer: Explainer | None = None
    if choice:
        name, api_key = choice
        try:
            explainer = CachedExplainer(PROVIDERS[name](
                api_key, settings.aisle_ai_model or DEFAULT_MODELS[name], settings.aisle_ai_timeout_seconds,
                settings.aisle_ai_reply_timeout_seconds, settings.aisle_ai_explain_timeout_seconds,
            ))
        except ImportError:
            log.warning("%s package not installed; no AI explanations", name)
    _cached_explainer = (key, explainer)
    return explainer


# OpenAI's moderation model: free, for text and photos, with any OpenAI key (whichever
# provider writes the answers).
MODERATION_MODEL = "omni-moderation-latest"
# A check that takes longer lets the message through rather than hold up the reply.
MODERATION_TIMEOUT_SECONDS = 3.0


class OpenAIModerator:
    def __init__(self, api_key: str, timeout: float = MODERATION_TIMEOUT_SECONDS):
        import openai  # Imported lazily so the fallback works without the SDK.

        self._client = openai.OpenAI(api_key=api_key, timeout=timeout, max_retries=0)

    def flagged(self, text: str, image: str | None = None) -> bool:
        content: str | list[dict] = text
        if image:
            content = [{"type": "text", "text": text}] if text else []
            content.append({"type": "image_url", "image_url": {"url": f"data:{_media_type(image)};base64,{image}"}})
        response = self._client.moderations.create(model=MODERATION_MODEL, input=content)
        return any(result.flagged for result in response.results)


_cached_moderator: tuple[tuple, Moderator | None] | None = None


def get_moderator() -> Moderator | None:
    """Moderation for what shoppers send the AI and what it writes back, or None without
    an OpenAI key or when turned off."""
    global _cached_moderator
    settings = get_settings()
    key = (settings.openai_api_key if settings.aisle_ai_moderation else None,)
    if _cached_moderator is not None and _cached_moderator[0] == key:
        return _cached_moderator[1]
    moderator: Moderator | None = None
    if key[0]:
        try:
            moderator = OpenAIModerator(key[0])
        except ImportError:
            log.warning("openai package not installed; no moderation")
    _cached_moderator = (key, moderator)
    return moderator
