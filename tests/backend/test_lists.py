import pytest
from fastapi.testclient import TestClient

from backend.app.ai.list_parser import MAX_ITEMS, parse_list
from backend.app.main import app


@pytest.fixture
def api():
    with TestClient(app) as client:
        yield client


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
