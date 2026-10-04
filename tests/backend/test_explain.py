from backend.app.ai.explain import CachedExplainer, ExplainFacts, explain_safely, facts_prompt, position_words, validate
from backend.app.ai.providers import get_explainer
from backend.app.main import app
from conftest import store_id_for


def facts(**overrides):
    base = dict(
        item="maple syrup", retailer="Costco", store_name="Costco King of Prussia",
        department="Pantry & Breakfast", aisle=None, section=None, category="Syrups & Sweeteners",
        neighbors=("pancake mix", "honey"), confidence="medium", availability="likely", source="fallback",
    )
    base.update(overrides)
    return ExplainFacts(**base)


class FakeExplainer:
    def __init__(self, text):
        self.text = text
        self.calls = 0

    def explain(self, facts):
        self.calls += 1
        return self.text


def test_rejects_an_invented_aisle_number():
    assert validate("At Costco, maple syrup is in **Aisle 7**, next to the pancake mix.", facts()) is None
    assert validate("At Costco, check aisles 4 and 5 near the honey.", facts()) is None


def test_allows_the_aisle_on_file_and_plain_department_text():
    on_file = facts(aisle="14", section="Left side", confidence="high", source="database")
    assert validate("At Costco, maple syrup is in **Aisle 14**, on the left side.", on_file)
    text = "At Costco, maple syrup is usually in **Pantry & Breakfast**, near the pancake mix and honey."
    assert validate(text, facts()) == text


def test_rejects_formatting_and_bad_lengths():
    assert validate("- At Costco it's in Pantry & Breakfast, near honey.", facts()) is None
    assert validate("At Costco it's in **Pantry & Breakfast, near honey.", facts()) is None
    assert validate("Pantry.", facts()) is None
    assert validate(None, facts()) is None


def test_whitespace_is_normalised():
    assert validate("At Costco,\n\nit's in  Pantry & Breakfast near honey.", facts()) == \
        "At Costco, it's in Pantry & Breakfast near honey."


def test_provider_errors_fall_back_to_none():
    class Broken:
        def explain(self, facts):
            raise RuntimeError("provider down")

    assert explain_safely(Broken(), facts()) is None
    assert explain_safely(None, facts()) is None


def test_cache_reuses_valid_answers_and_retries_failures():
    good = FakeExplainer("At Costco, maple syrup is usually in Pantry & Breakfast, near honey.")
    cached = CachedExplainer(good)
    assert cached.explain(facts()) == cached.explain(facts())
    assert good.calls == 1
    bad = FakeExplainer("It's in aisle 9.")
    cached_bad = CachedExplainer(bad)
    assert cached_bad.explain(facts()) is None and cached_bad.explain(facts()) is None
    assert bad.calls == 2


def test_prompt_contains_only_the_facts():
    prompt = facts_prompt(facts(position="toward the back left of the store"))
    assert "Store: Costco (Costco King of Prussia)" in prompt
    assert "Aisle: none on file" in prompt
    assert "Position in store: toward the back left of the store (from a typical layout" in prompt


def test_position_words():
    assert position_words(0.1, 0.9) == "toward the back left of the store"
    assert position_words(0.5, 0.1) == "toward the front of the store"
    assert position_words(0.9, 0.5) == "along the right side of the store"
    assert position_words(0.5, 0.5) == "the middle of the store"
    assert position_words(None, 0.5) is None


def test_search_returns_a_checked_explanation(seeded_client):
    fake = FakeExplainer("At Costco, maple syrup is usually in **Pantry & Breakfast**, near the pancake mix.")
    app.dependency_overrides[get_explainer] = lambda: fake
    store_id = store_id_for(seeded_client, "Costco")
    data = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    assert data["explanation"] == fake.text

    fake.text = "Go to aisle 12."
    data = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    assert data["explanation"] is None


def test_search_without_explainer_has_no_explanation(seeded_client):
    store_id = store_id_for(seeded_client, "Costco")
    data = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    assert data["explanation"] is None


def test_layout_endpoint(seeded_client):
    store_id = store_id_for(seeded_client, "Costco")
    layout = seeded_client.get(f"/stores/{store_id}/layout").json()
    assert layout["approximate"] is True
    assert layout["entrance"] and layout["checkout"]
    assert any(z["name"] == "Pantry & Breakfast" for z in layout["zones"])
    assert all(0 <= z["x"] <= 1 and 0 <= z["y"] <= 1 for z in layout["zones"] if z["x"] is not None)
    assert seeded_client.get("/stores/999999/layout").status_code == 404
