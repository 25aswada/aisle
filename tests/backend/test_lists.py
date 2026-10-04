import pytest
from fastapi.testclient import TestClient

from backend.app.ai.list_parser import MAX_ITEMS, parse_list
from backend.app.main import app


@pytest.fixture
def api(engine):
    from sqlalchemy.orm import Session

    from backend.app.database import get_db
    from conftest import signed_in_headers

    def override_db():
        with Session(engine) as session:
            yield session

    app.dependency_overrides[get_db] = override_db
    with TestClient(app, headers=signed_in_headers(engine)) as client:
        yield client
    app.dependency_overrides.clear()


def test_space_separated_items_become_four(api):
    response = api.post("/lists/parse", json={"text": "milk eggs bananas toothpaste"})
    assert response.status_code == 200
    items = response.json()["items"]
    assert [i["text"] for i in items] == ["milk", "eggs", "bananas", "toothpaste"]
    assert [i["category"]["slug"] for i in items] == ["dairy", "eggs", "produce-fruit", "oral-care"]
    assert all(i["quantity"] is None for i in items)


@pytest.mark.parametrize("text, expected", [
    ("milk eggs bananas toothpaste", ["milk", "eggs", "bananas", "toothpaste"]),
    ("maple syrup paper towels peanut butter", ["maple syrup", "paper towels", "peanut butter"]),
    ("2 milk, maple syrup\nhalf and half", ["milk", "maple syrup", "half and half"]),
    ("eggs and bread and peanut butter", ["eggs", "bread", "peanut butter"]),
    ("- milk\n- 12 eggs\n* paper towels", ["milk", "eggs", "paper towels"]),
    ("mac and cheese, ice cream", ["mac and cheese", "ice cream"]),
    ("organic bananas whole milk flux capacitor ice cream",
     ["organic bananas", "whole milk", "flux capacitor", "ice cream"]),
    ("chocolate chip cookies, oat milk", ["chocolate chip cookies", "oat milk"]),
    ("dinner rolls butter", ["dinner rolls", "butter"]),
    ("", []),
    ("  \n , ", []),
])
def test_parse_list(text, expected):
    assert [i.text for i in parse_list(text)] == expected


def test_quantities_attach_to_their_item():
    items = parse_list("3 apples 2 lemons half gallon milk a dozen eggs")
    assert [(i.text, i.quantity) for i in items] == [
        ("apples", "3"), ("lemons", "2"), ("milk", "half gallon"), ("eggs", "a dozen"),
    ]


def test_unknown_items_have_no_category(api):
    items = api.post("/lists/parse", json={"text": "flux capacitor, milk"}).json()["items"]
    assert items[0] == {"text": "flux capacitor", "quantity": None, "category": None}


def test_item_limit_and_validation(api):
    assert len(parse_list(", ".join(["milk"] * 150))) == MAX_ITEMS
    assert api.post("/lists/parse", json={"text": "x" * 2001}).status_code == 422
    assert api.post("/lists/parse", json={}).status_code == 422


# --- Photographed lists ---

import base64

from backend.app.ai.explain import READ_LIST_PROMPT
from backend.app.ai.providers import get_explainer

PHOTO = base64.b64encode(b"\xff\xd8\xff\xe0 a photo of a list").decode()


class ListReader:
    def __init__(self, text):
        self.text = text
        self.chats = []

    def chat(self, system, messages):
        self.chats.append((system, messages))
        return self.text


@pytest.fixture
def reader(engine):
    from sqlalchemy.orm import Session

    from backend.app.database import get_db

    def override_db():
        with Session(engine) as session:
            yield session

    fake = ListReader("2 lbs chicken\nhalf and half\nbananas")
    app.dependency_overrides[get_explainer] = lambda: fake
    # Scans count against the free tier's daily photo searches.
    app.dependency_overrides[get_db] = override_db
    yield fake
    app.dependency_overrides.pop(get_explainer, None)
    app.dependency_overrides.pop(get_db, None)


def test_scan_reads_the_photo_then_parses_it_like_typed_text(api, reader):
    items = api.post("/lists/scan", json={"image": PHOTO}).json()["items"]
    assert [i["text"] for i in items] == ["chicken", "half and half", "bananas"]
    assert items[0]["quantity"] == "2 lbs"
    assert items[2]["category"]["slug"] == "produce-fruit"
    system, messages = reader.chats[0]
    assert system == READ_LIST_PROMPT
    assert messages[0]["image"] == PHOTO


def test_scan_without_a_list_has_no_items(api, reader):
    reader.text = "NONE"
    assert api.post("/lists/scan", json={"image": PHOTO}).json() == {"items": []}
    app.dependency_overrides[get_explainer] = lambda: None
    assert api.post("/lists/scan", json={"image": PHOTO}).json() == {"items": []}


def test_scan_rejects_a_non_photo(api, reader):
    not_a_photo = base64.b64encode(b"hello").decode()
    assert api.post("/lists/scan", json={"image": not_a_photo}).status_code == 422
