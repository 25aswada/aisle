import json
import re

import pytest

from backend.app.ai.catalog import LAYOUTS, layout_for_retailer
from backend.app.ai.evaluate import check, load_cases
from backend.app.ai.intent import parse_intent
from backend.app.ai.providers import get_location_model, guess_from_model_output
from backend.app.ai.reasoning import fallback_guess
from backend.app.main import app

from conftest import store_id_for

AISLE_NUMBER = re.compile(r"aisle\s*#?\s*\d+", re.IGNORECASE)


def test_trader_joes_maple_syrup(seeded_client):
    store_id = store_id_for(seeded_client, "Trader Joe's")
    response = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id})
    assert response.status_code == 200
    data = response.json()
    assert data["location"]["department"] == "Breakfast/Pantry"
    assert {"pancake mix", "sweeteners"} <= set(data["location"]["neighbors"])
    assert data["confidence"] == "medium"
    assert data["location"]["aisle"] is None
    assert data["location"]["section"] is None
    assert not AISLE_NUMBER.search(json.dumps(data))
    assert data["category"] == {"slug": "syrups-sweeteners", "name": "Syrups & Sweeteners"}
    assert data["item"] == "maple syrup"
    assert data["source"] == "fallback"


def test_natural_language_query_is_parsed(seeded_client):
    store_id = store_id_for(seeded_client, "Trader Joe's")
    data = seeded_client.post(
        "/search", json={"query": "Where can I find organic maple syrup?", "store_id": store_id}
    ).json()
    assert data["item"] == "maple syrup"
    assert data["modifiers"] == ["organic"]
    assert data["location"]["department"] == "Breakfast/Pantry"


def test_search_without_store_uses_generic_grocery_layout(seeded_client):
    data = seeded_client.post("/search", json={"query": "milk"}).json()
    assert data["store_id"] is None
    assert data["location"]["department"] == "Dairy & Eggs"


def test_unknown_item_is_low_confidence_without_department(seeded_client):
    data = seeded_client.post("/search", json={"query": "flux capacitor"}).json()
    assert data["confidence"] == "low"
    assert data["location"]["department"] is None
    assert data["category"] is None


def test_item_a_store_does_not_carry(seeded_client):
    store_id = store_id_for(seeded_client, "Home Depot")
    data = seeded_client.post("/search", json={"query": "milk", "store_id": store_id}).json()
    assert data["availability"] == "unlikely"
    assert data["confidence"] == "low"


@pytest.mark.parametrize("body", [{"query": ""}, {"query": "   "}, {}, {"query": "x" * 201}])
def test_search_validation(seeded_client, body):
    assert seeded_client.post("/search", json=body).status_code == 422


def test_search_unknown_store(seeded_client):
    response = seeded_client.post("/search", json={"query": "milk", "store_id": 99999})
    assert response.status_code == 404


@pytest.mark.parametrize("case", load_cases(), ids=lambda c: f"{c['retailer']}:{c['query']}")
def test_fallback_eval_cases(case):
    guess = fallback_guess(parse_intent(case["query"]), layout_for_retailer(case["retailer"]))
    assert check(case, guess) == []


@pytest.mark.parametrize("query, item, quantity, slug", [
    ("2 gallons of whole milk", "whole milk", "2 gallons", "dairy"),
    ("a dozen eggs", "eggs", "a dozen", "eggs"),
    ("milk chocolate", "milk chocolate", None, "sweets"),
    ("chocolate milk", "chocolate milk", None, "dairy"),
    ("cookies", "cookies", None, "sweets"),
    ("light bulbs", "light bulbs", None, "batteries-bulbs"),
    ("frozen peas", "frozen peas", None, "frozen"),
])
def test_intent_parsing(query, item, quantity, slug):
    intent = parse_intent(query)
    assert intent.item == item
    assert intent.quantity == quantity
    assert intent.match.category.slug == slug


# AI provider: output is validated against the store layout.

def test_model_output_cannot_add_aisle_numbers_or_off_list_departments():
    layout = LAYOUTS["trader_joes"]
    intent = parse_intent("maple syrup")
    guess = guess_from_model_output({
        "item": "maple syrup", "category": "syrups-sweeteners", "department": "Aisle 7",
        "neighbors": ["Aisle 7 endcap", "pancake mix", "maple syrup", "honey"],
        "carried": "likely", "confidence": "medium",
    }, intent, layout)
    # "Aisle 7" is not a department on the list, so the category name is used instead.
    assert guess.department == "Syrups & Sweeteners"
    assert guess.neighbors == ["pancake mix", "honey"]
    assert guess.confidence == "low"


def test_model_output_maps_to_layout_department():
    guess = guess_from_model_output({
        "item": "dragon fruit", "category": "produce-fruit", "department": "Flowers & Produce",
        "neighbors": ["mangoes", "papaya"], "carried": "likely", "confidence": "medium",
    }, parse_intent("dragon fruit"), LAYOUTS["trader_joes"])
    assert (guess.department, guess.confidence, guess.source) == ("Flowers & Produce", "medium", "model")


class FakeModel:
    name = "fake"

    def __init__(self, guess_data=None):
        self.guess_data = guess_data
        self.calls = []

    def locate(self, intent, retailer_name, layout):
        self.calls.append(intent.raw)
        if self.guess_data is None:
            return None  # Simulates a provider error.
        return guess_from_model_output(self.guess_data, intent, layout)


def _with_model(model):
    app.dependency_overrides[get_location_model] = lambda: model


def test_model_handles_catalog_misses(seeded_client):
    model = FakeModel({
        "item": "durian", "category": "produce-fruit", "department": "Produce",
        "neighbors": ["jackfruit"], "carried": "likely", "confidence": "medium",
    })
    _with_model(model)
    data = seeded_client.post("/search", json={"query": "durian"}).json()
    assert data["source"] == "model"
    assert data["location"]["department"] == "Produce"
    # Catalog hits don't call the model under the default strategy.
    seeded_client.post("/search", json={"query": "milk"})
    assert model.calls == ["durian"]


def test_model_failure_falls_back(seeded_client):
    _with_model(FakeModel(None))
    data = seeded_client.post("/search", json={"query": "flux capacitor"}).json()
    assert data["source"] == "fallback"
    assert data["confidence"] == "low"


def test_model_first_strategy(seeded_client, monkeypatch):
    from backend.app.config import get_settings

    monkeypatch.setattr(get_settings(), "aisle_ai_strategy", "model_first")
    model = FakeModel(None)
    _with_model(model)
    store_id = store_id_for(seeded_client, "Trader Joe's")
    data = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    assert model.calls == ["maple syrup"]
    assert data["location"]["department"] == "Breakfast/Pantry"


def test_no_api_key_means_no_model(monkeypatch):
    from backend.app.config import get_settings

    monkeypatch.setattr(get_settings(), "anthropic_api_key", None)
    monkeypatch.setattr(get_settings(), "openai_api_key", None)
    assert get_location_model() is None


@pytest.mark.parametrize("provider, anthropic_key, openai_key, expected", [
    ("auto", "a-key", "o-key", "anthropic"),
    ("auto", None, "o-key", "openai"),
    ("openai", "a-key", "o-key", "openai"),
    ("anthropic", None, "o-key", None),
])
def test_provider_selection(monkeypatch, provider, anthropic_key, openai_key, expected):
    from backend.app.ai import providers
    from backend.app.config import get_settings

    settings = get_settings()
    monkeypatch.setattr(settings, "aisle_ai_provider", provider)
    monkeypatch.setattr(settings, "anthropic_api_key", anthropic_key)
    monkeypatch.setattr(settings, "openai_api_key", openai_key)
    choice = providers._choose_provider(settings)
    assert (choice[0] if choice else None) == expected


def test_openai_model_parses_structured_output():
    from types import SimpleNamespace

    from backend.app.ai.providers import OpenAILocationModel

    content = json.dumps({
        "item": "maple syrup", "category": "syrups-sweeteners", "department": "Breakfast/Pantry",
        "neighbors": ["pancake mix"], "carried": "likely", "confidence": "medium",
    })
    sent = {}

    def create(**kwargs):
        sent.update(kwargs)
        message = SimpleNamespace(content=content, refusal=None)
        return SimpleNamespace(choices=[SimpleNamespace(finish_reason="stop", message=message)])

    model = OpenAILocationModel("test-key", "gpt-6-luna", timeout=1)
    model._client = SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=create)))
    guess = model.locate(parse_intent("maple syrup"), "Trader Joe's", LAYOUTS["trader_joes"])
    assert sent["model"] == "gpt-6-luna"
    assert sent["response_format"]["json_schema"]["strict"] is True
    assert guess.department == "Breakfast/Pantry"
    assert guess.source == "model"
