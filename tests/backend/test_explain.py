import base64

from backend.app.ai.explain import (
    FIND_PROMPT, CachedExplainer, ExplainFacts, clean_item_phrase, explain_safely, facts_prompt, position_words,
    validate,
)
from backend.app.ai.providers import _anthropic_content, _openai_content
from backend.app.ai.providers import get_explainer
from backend.app.main import app
from conftest import store_id_for


def facts(**overrides):
    base = dict(
        item="maple syrup", retailer="Costco", store_name="Costco King of Prussia",
        department="Pantry Grocery", aisle=None, section=None, category="Syrups & Sweeteners",
        neighbors=("pancake mix", "honey"), confidence="medium", availability="likely", source="fallback",
    )
    base.update(overrides)
    return ExplainFacts(**base)


class FakeExplainer:
    """Answers with `text`; the follow-up "new item?" check gets `find` instead."""

    def __init__(self, text, find="NONE"):
        self.text = text
        self.find = find
        self.calls = 0
        self.chats = []

    def explain(self, facts):
        self.calls += 1
        return self.text

    def chat(self, system, messages):
        if system == FIND_PROMPT:
            return self.find
        self.chats.append((system, messages))
        return self.text


def test_reply_passes_through_as_written():
    text = (
        "At Costco, the big trays of Kirkland cookies are usually in **Bakery & Floral** along "
        "the back wall.\n\nPackaged cookies sit with the snacks near the front."
    )
    assert validate(text, facts()) == text
    assert validate("  It's in aisle 9.  ", facts()) == "It's in aisle 9."


def test_empty_reply_falls_back():
    assert validate(None, facts()) is None
    assert validate("   ", facts()) is None


def test_provider_errors_fall_back_to_none():
    class Broken:
        def explain(self, facts):
            raise RuntimeError("provider down")

    assert explain_safely(Broken(), facts()) is None
    assert explain_safely(None, facts()) is None


def test_cache_reuses_valid_answers_and_retries_failures():
    good = FakeExplainer("At Costco, maple syrup is usually in Pantry Grocery, near honey.")
    cached = CachedExplainer(good)
    assert cached.explain(facts()) == cached.explain(facts())
    assert good.calls == 1
    bad = FakeExplainer("")
    cached_bad = CachedExplainer(bad)
    assert cached_bad.explain(facts()) is None and cached_bad.explain(facts()) is None
    assert bad.calls == 2


def test_layout_guesses_stay_out_of_the_prompt():
    prompt = facts_prompt(facts(position="toward the back left of the store"))
    assert prompt == "Where can I find maple syrup at Costco King of Prussia?"
    assert "Pantry Grocery" not in facts_prompt(facts(source="model"))


def test_store_data_goes_in_with_the_question():
    prompt = facts_prompt(facts(
        aisle="14", section="Left side", source="database", modifiers=("organic",),
        found_reports=3, not_here_reports=1,
    ))
    assert prompt.startswith("Where can I find maple syrup at Costco King of Prussia? (I'm looking for: organic.)")
    assert "Aisle: 14" in prompt and "Section: Left side" in prompt
    assert "Shopper reports: 3 found it there, 1 did not" in prompt
    assert "Shelved near: pancake mix, honey" in prompt


def test_position_words():
    assert position_words(0.1, 0.9) == "toward the back left of the store"
    assert position_words(0.5, 0.1) == "toward the front of the store"
    assert position_words(0.9, 0.5) == "along the right side of the store"
    assert position_words(0.5, 0.5) == "the middle of the store"
    assert position_words(None, 0.5) is None


def test_search_returns_a_checked_explanation(seeded_client):
    fake = FakeExplainer("At Costco, maple syrup is usually in **Pantry Grocery**, near the pancake mix.")
    app.dependency_overrides[get_explainer] = lambda: fake
    store_id = store_id_for(seeded_client, "Costco")
    data = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    assert data["explanation"] == fake.text

    fake.text = ""
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
    assert any(z["name"] == "Pantry Grocery" for z in layout["zones"])
    assert all(0 <= z["x"] <= 1 and 0 <= z["y"] <= 1 for z in layout["zones"] if z["x"] is not None)
    assert seeded_client.get("/stores/999999/layout").status_code == 404


CONVERSATION = [
    {"role": "user", "content": "cookies"},
    {"role": "assistant", "content": "Head to the bakery along the back wall."},
    {"role": "user", "content": "I'm at the bakery and don't see them"},
]


def test_chat_sends_the_conversation_and_store(seeded_client):
    fake = FakeExplainer("Check the tables in front of the ovens, by the muffins.")
    app.dependency_overrides[get_explainer] = lambda: fake
    store_id = store_id_for(seeded_client, "Costco")
    response = seeded_client.post("/chat", json={"store_id": int(store_id), "messages": CONVERSATION})
    assert response.status_code == 200
    assert response.json() == {"reply": fake.text, "search": None}
    system, messages = fake.chats[0]
    assert messages == CONVERSATION
    assert "follow-up" in system and "Costco" in system


def test_chat_without_a_provider_or_on_failure_has_no_reply(seeded_client):
    store_id = int(store_id_for(seeded_client, "Costco"))
    assert seeded_client.post("/chat", json={"store_id": store_id, "messages": CONVERSATION}).json() == {"reply": None, "search": None}

    class Broken(FakeExplainer):
        def chat(self, system, messages):
            raise RuntimeError("provider down")

    app.dependency_overrides[get_explainer] = lambda: Broken("")
    assert seeded_client.post("/chat", json={"store_id": store_id, "messages": CONVERSATION}).json() == {"reply": None, "search": None}


def test_chat_validates_the_conversation(seeded_client):
    store_id = int(store_id_for(seeded_client, "Costco"))
    ends_with_aisle = CONVERSATION[:2]
    assert seeded_client.post("/chat", json={"store_id": store_id, "messages": ends_with_aisle}).status_code == 422
    assert seeded_client.post("/chat", json={"store_id": store_id, "messages": []}).status_code == 422
    assert seeded_client.post("/chat", json={"store_id": 999999, "messages": CONVERSATION}).status_code == 404


JPEG = base64.b64encode(b"\xff\xd8\xff\xe0 a tiny jpeg").decode()


def test_chat_passes_a_photo_with_the_shoppers_message(seeded_client):
    fake = FakeExplainer("That's the Kirkland tray; it's the right one.")
    app.dependency_overrides[get_explainer] = lambda: fake
    store_id = int(store_id_for(seeded_client, "Costco"))
    messages = CONVERSATION[:2] + [{"role": "user", "content": "", "image": JPEG}]
    assert seeded_client.post("/chat", json={"store_id": store_id, "messages": messages}).json()["reply"] == fake.text
    assert fake.chats[0][1][-1] == {"role": "user", "content": "", "image": JPEG}


def test_chat_rejects_bad_photos(seeded_client):
    store_id = int(store_id_for(seeded_client, "Costco"))
    not_a_photo = base64.b64encode(b"hello").decode()
    for messages in (
        CONVERSATION[:2] + [{"role": "user", "content": "this?", "image": not_a_photo}],
        CONVERSATION[:2] + [{"role": "user", "content": "this?", "image": "%%%"}],
        [{"role": "user", "content": "cookies"}, {"role": "assistant", "content": "ok", "image": JPEG},
         {"role": "user", "content": "this?"}],
        CONVERSATION[:2] + [{"role": "user", "content": "  "}],
    ):
        assert seeded_client.post("/chat", json={"store_id": store_id, "messages": messages}).status_code == 422


def test_identify_names_the_photo(seeded_client):
    fake = FakeExplainer(' "Chocolate chip cookies." ')
    app.dependency_overrides[get_explainer] = lambda: fake
    store_id = int(store_id_for(seeded_client, "Costco"))
    body = {"store_id": store_id, "image": JPEG, "note": "where are these"}
    assert seeded_client.post("/identify", json=body).json() == {"item": "Chocolate chip cookies"}
    system, messages = fake.chats[0]
    assert "search phrase" in system
    assert messages == [{"role": "user", "content": "where are these", "image": JPEG}]

    fake.text = "NONE"
    assert seeded_client.post("/identify", json=body).json() == {"item": None}
    assert seeded_client.post("/identify", json={**body, "store_id": 999999}).status_code == 404
    assert seeded_client.post("/identify", json={**body, "image": "nope"}).status_code == 422


def test_identify_without_a_provider_has_no_item(seeded_client):
    assert seeded_client.post("/identify", json={"image": JPEG}).json() == {"item": None}


def test_clean_item_phrase():
    assert clean_item_phrase("  oat\nmilk. ") == "oat milk"
    assert clean_item_phrase("none") is None
    assert clean_item_phrase("") is None
    assert clean_item_phrase("x" * 61) is None


def test_providers_format_photos():
    plain = {"role": "user", "content": "cookies"}
    assert _anthropic_content(plain) == "cookies" and _openai_content(plain) == "cookies"
    photo = {"role": "user", "content": "", "image": JPEG}
    anthropic = _anthropic_content(photo)
    assert anthropic[0]["source"] == {"type": "base64", "media_type": "image/jpeg", "data": JPEG}
    assert anthropic[1] == {"type": "text", "text": "(photo)"}
    openai = _openai_content({**photo, "content": "this one?"})
    assert openai[0] == {"type": "text", "text": "this one?"}
    assert openai[1]["image_url"]["url"] == f"data:image/jpeg;base64,{JPEG}"


def test_follow_up_asking_for_a_new_item_brings_its_search(seeded_client):
    fake = FakeExplainer("Maple syrup is usually in the center aisles by the pancake mix.", find="maple syrup")
    app.dependency_overrides[get_explainer] = lambda: fake
    store_id = int(store_id_for(seeded_client, "Costco"))
    messages = CONVERSATION[:2] + [{"role": "user", "content": "ok where's the maple syrup?"}]
    data = seeded_client.post("/chat", json={"store_id": store_id, "messages": messages}).json()
    assert data["reply"] == fake.text
    search = data["search"]
    assert search["item"] == "maple syrup"
    assert search["store_id"] == store_id
    assert search["location"]["department"]
    assert search["explanation"] is None
    assert search["search_id"]


def test_conversational_follow_up_has_no_search(seeded_client):
    fake = FakeExplainer("Usually around $20 for a 24-pack.")
    app.dependency_overrides[get_explainer] = lambda: fake
    store_id = int(store_id_for(seeded_client, "Costco"))
    messages = CONVERSATION[:2] + [{"role": "user", "content": "how much are they?"}]
    assert seeded_client.post("/chat", json={"store_id": store_id, "messages": messages}).json()["search"] is None
