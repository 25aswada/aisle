"""The AI's daily budget in dollars: what each provider call costs and how it's
counted, the output caps each call is sent with, and logs and error reports."""
import base64
import logging
from contextvars import copy_context
from types import SimpleNamespace

import anthropic
import httpx
import pytest
from sqlalchemy.orm import Session

from backend.app import monitoring
from backend.app.ai import budget
from backend.app.ai.explain import EXPLAIN_SYSTEM_PROMPT, FIND_PROMPT, IDENTIFY_PROMPT, READ_LIST_PROMPT
from backend.app.ai.catalog import LAYOUTS
from backend.app.ai.intent import parse_intent
from backend.app.ai.providers import (
    LIST_MAX_TOKENS, LOCATE_MAX_TOKENS, PHRASE_MAX_TOKENS, REPLY_MAX_TOKENS, AnthropicLocationModel,
    OpenAILocationModel,
)
from backend.app.config import get_settings

PHOTO = base64.b64encode(b"\xff\xd8\xff\xe0" + b"a big photo" * 20_000).decode()


def metered(engine, call):
    """Runs `call` charging to `engine`'s database, as a request does, without leaving the
    meter running for other tests."""
    def run():
        with Session(engine) as db:
            budget.start_metering(db)
        return call()
    return copy_context().run(run)


def spent(engine) -> float:
    with Session(engine) as db:
        return budget.spent_today(db)


class FakeAnthropic:
    """Records what each call sent, and answers with the given usage (None for none)."""

    def __init__(self, usage=(1000, 500), text="By the eggs.", error=None):
        self.sent, self.usage, self.text, self.error = [], usage, text, error
        self.messages = SimpleNamespace(create=self.create)
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self.create))

    def create(self, **kwargs):
        self.sent.append(kwargs)
        if self.error:
            raise self.error
        usage = SimpleNamespace(input_tokens=self.usage[0], output_tokens=self.usage[1]) if self.usage else None
        return SimpleNamespace(stop_reason="end_turn", model=kwargs["model"], usage=usage,
                               content=[SimpleNamespace(type="text", text=self.text)])


def anthropic_model(client):
    model = AnthropicLocationModel("test-key", "claude-opus-5-5", timeout=1)
    model._client = client
    return model


class FakeOpenAI:
    def __init__(self, usage=(1000, 500), content="By the eggs."):
        self.sent, self.usage, self.content = [], usage, content
        self.chat = SimpleNamespace(completions=SimpleNamespace(create=self.create))

    def create(self, **kwargs):
        self.sent.append(kwargs)
        usage = SimpleNamespace(prompt_tokens=self.usage[0], completion_tokens=self.usage[1]) if self.usage else None
        message = SimpleNamespace(content=self.content, refusal=None)
        return SimpleNamespace(model=kwargs["model"], usage=usage,
                               choices=[SimpleNamespace(finish_reason="stop", message=message)])


def openai_model(client, name="gpt-5"):
    model = OpenAILocationModel("test-key", name, timeout=1)
    model._client = client
    return model


# MARK: - Prices

def test_prices_come_from_one_table_with_a_cautious_fallback():
    assert budget.price_for("claude-opus-5-5") == (4.0, 20.0)
    assert budget.price_for("claude-sonnet-5-5") == (2.0, 10.0)
    assert budget.price_for("gpt-5-2025-08-07") == (1.25, 10.0)
    assert budget.price_for("gpt-5-mini-2025-08-07") == (0.25, 2.0)
    # The production default model.
    assert budget.price_for("gpt-6-luna") == (0.10, 0.50)
    assert budget.price_for("some-new-model") == budget.UNKNOWN_PRICE
    assert budget.price_for(None) == budget.UNKNOWN_PRICE
    assert budget.UNKNOWN_PRICE >= max(budget.PRICES.values())
    # A million tokens in and out on Opus 5.5.
    assert budget.cost_usd("claude-opus-5-5", 1_000_000, 1_000_000) == 24.0


def test_estimates_count_photos_as_images_not_base64():
    text = [{"role": "user", "content": "What is this?"}]
    photo = [{"role": "user", "content": "What is this?", "image": PHOTO}]
    difference = budget.estimate_prompt_tokens("", photo) - budget.estimate_prompt_tokens("", text)
    assert difference == budget.IMAGE_TOKENS
    assert budget.estimate_tokens("x" * 400) == 100


# MARK: - Charging calls

def test_each_call_adds_to_todays_spend(engine):
    model = anthropic_model(FakeAnthropic(usage=(1000, 500)))
    for expected in (0.014, 0.028):
        metered(engine, lambda: model.chat(EXPLAIN_SYSTEM_PROMPT, [{"role": "user", "content": "milk?"}]))
        assert spent(engine) == pytest.approx(expected)


def test_location_guesses_are_charged_too(engine):
    client = FakeOpenAI(usage=(800, 100), content="{}")
    model = openai_model(client)
    metered(engine, lambda: model.locate(parse_intent("maple syrup"), "Trader Joe's", LAYOUTS["trader_joes"]))
    assert spent(engine) == pytest.approx(budget.cost_usd("gpt-5", 800, 100))


def test_photo_calls_cost_more(engine):
    """Without usage in the response, the cost is estimated, and a photo adds an image's worth."""
    model = anthropic_model(FakeAnthropic(usage=None, text="milk"))
    metered(engine, lambda: model.chat(IDENTIFY_PROMPT, [{"role": "user", "content": "What is this?"}]))
    text_cost = spent(engine)
    metered(engine, lambda: model.chat(IDENTIFY_PROMPT, [{"role": "user", "content": "What is this?", "image": PHOTO}]))
    photo_cost = spent(engine) - text_cost
    assert photo_cost > text_cost > 0
    assert photo_cost - text_cost == pytest.approx(budget.cost_usd("claude-opus-5-5", budget.IMAGE_TOKENS, 0),
                                                   abs=2e-6)


def test_reported_usage_is_preferred_over_estimates(engine):
    model = openai_model(FakeOpenAI(usage=(3000, 40)))
    metered(engine, lambda: model.chat(IDENTIFY_PROMPT, [{"role": "user", "content": "this?", "image": PHOTO}]))
    assert spent(engine) == pytest.approx(budget.cost_usd("gpt-5", 3000, 40))


def test_a_timed_out_call_is_charged_its_full_cap(engine):
    timeout = anthropic.APITimeoutError(request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"))
    model = anthropic_model(FakeAnthropic(error=timeout))
    messages = [{"role": "user", "content": "x" * 400}]
    with pytest.raises(anthropic.APITimeoutError):
        metered(engine, lambda: model.chat(EXPLAIN_SYSTEM_PROMPT, messages))
    prompt = budget.estimate_prompt_tokens(EXPLAIN_SYSTEM_PROMPT, messages)
    assert spent(engine) == pytest.approx(budget.cost_usd("claude-opus-5-5", prompt, REPLY_MAX_TOKENS), abs=2e-6)


def test_calls_outside_a_request_arent_recorded(engine):
    model = anthropic_model(FakeAnthropic())
    model.chat(EXPLAIN_SYSTEM_PROMPT, [{"role": "user", "content": "milk?"}])
    assert spent(engine) == 0


def test_budget_spent_at_the_limit(engine, monkeypatch):
    monkeypatch.setattr(get_settings(), "aisle_ai_budget_usd_per_day", 0.02)
    model = anthropic_model(FakeAnthropic(usage=(1000, 500)))
    with Session(engine) as db:
        assert not budget.budget_spent(db)
    metered(engine, lambda: model.chat(EXPLAIN_SYSTEM_PROMPT, [{"role": "user", "content": "milk?"}]))
    with Session(engine) as db:
        assert not budget.budget_spent(db)
    metered(engine, lambda: model.chat(EXPLAIN_SYSTEM_PROMPT, [{"role": "user", "content": "eggs?"}]))
    with Session(engine) as db:
        assert budget.budget_spent(db)
    monkeypatch.setattr(get_settings(), "aisle_ai_budget_usd_per_day", 0.0)
    with Session(engine) as db:
        assert budget.budget_spent(db)  # 0 turns the AI off.


# MARK: - Output caps

@pytest.mark.parametrize("system, cap", [
    (EXPLAIN_SYSTEM_PROMPT, REPLY_MAX_TOKENS),
    ("A follow-up's own system prompt", REPLY_MAX_TOKENS),
    (IDENTIFY_PROMPT, PHRASE_MAX_TOKENS),
    (FIND_PROMPT, PHRASE_MAX_TOKENS),
    (READ_LIST_PROMPT, LIST_MAX_TOKENS),
])
def test_every_call_has_an_output_cap_sized_for_its_use(system, cap):
    claude, gpt = FakeAnthropic(), FakeOpenAI()
    anthropic_model(claude).chat(system, [{"role": "user", "content": "hi"}])
    openai_model(gpt).chat(system, [{"role": "user", "content": "hi"}])
    assert claude.sent[0]["max_tokens"] == cap
    assert gpt.sent[0]["max_completion_tokens"] == cap and "max_tokens" not in gpt.sent[0]


def test_location_guesses_have_an_output_cap():
    claude, gpt = FakeAnthropic(text="{}"), FakeOpenAI(content="{}")
    for model in (anthropic_model(claude), openai_model(gpt)):
        model.locate(parse_intent("maple syrup"), "Trader Joe's", LAYOUTS["trader_joes"])
    assert claude.sent[0]["max_tokens"] == LOCATE_MAX_TOKENS
    assert gpt.sent[0]["max_completion_tokens"] == LOCATE_MAX_TOKENS
    assert PHRASE_MAX_TOKENS < REPLY_MAX_TOKENS


# MARK: - Logs and error reports

def test_logging_goes_to_stdout_at_the_configured_level(monkeypatch):
    root = logging.getLogger()
    before = (root.level, list(root.handlers))
    try:
        settings = get_settings()
        monkeypatch.setattr(settings, "aisle_log_level", "warning")
        monitoring.configure_logging(settings)
        monitoring.configure_logging(settings)
        assert root.level == logging.WARNING
        ours = [h for h in root.handlers if getattr(h, "_aisle", False)]
        assert len(ours) == 1 and ours[0].formatter._fmt == monitoring.FORMAT
        monkeypatch.setattr(settings, "aisle_log_level", "nonsense")
        monitoring.configure_logging(settings)
        assert root.level == logging.INFO
        assert logging.getLogger("httpx").level == logging.WARNING
    finally:
        root.setLevel(before[0])
        root.handlers[:] = before[1]


def test_sentry_is_off_without_a_dsn(monkeypatch):
    monkeypatch.setattr(get_settings(), "sentry_dsn", None)
    assert monitoring.init_sentry(get_settings()) is False


def test_error_reports_carry_nothing_personal():
    event = {
        "request": {
            "url": "https://api.shopaisle.app/stores/nearby?lat=40.1&lon=-75.2",
            "query_string": "lat=40.1&lon=-75.2",
            "data": {"email": "sam@example.com", "code": "123456", "image": PHOTO},
            "cookies": {"session": "secret"},
            "env": {"REMOTE_ADDR": "203.0.113.9"},
            "headers": {"Authorization": "Bearer abc", "X-Forwarded-For": "203.0.113.9",
                        "X-Aisle-Device": "phone", "User-Agent": "Aisle/1.0", "Content-Type": "application/json"},
        },
        "user": {"ip_address": "203.0.113.9"},
        "exception": {"values": [{"type": "ValueError"}]},
    }
    scrubbed = monitoring.scrub_event(event, {})
    request = scrubbed["request"]
    assert request["url"] == "https://api.shopaisle.app/stores/nearby"
    assert set(request) == {"url", "headers"}
    assert request["headers"] == {"User-Agent": "Aisle/1.0", "Content-Type": "application/json"}
    assert "user" not in scrubbed and scrubbed["exception"]
    crumb = monitoring.scrub_breadcrumb(
        {"category": "httplib", "data": {"url": "https://example.com/v?token=abc", "http.query": "token=abc"}}, {})
    assert crumb["data"] == {"url": "https://example.com/v"}
