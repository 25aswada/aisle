"""Multi-store trips (Aisle+): each item goes to the first store likely to carry it,
and each store gets its own walking route."""
import pytest

from backend.app.plus import appstore
from conftest import store_id_for
from test_plus import FakeApple, account

PLUS = {"X-Aisle-Device": "plus-phone"}


@pytest.fixture
def plus(seeded_client, seeded_engine, monkeypatch):
    fake = FakeApple()
    monkeypatch.setattr(appstore, "apple_root", lambda: fake.root)
    # Aisle+ belongs to an account: sign one in on this device for the module's PLUS headers.
    headers, token, _ = account(seeded_engine, PLUS["X-Aisle-Device"])
    monkeypatch.setitem(PLUS, "Authorization", headers["Authorization"])
    synced = seeded_client.post("/plus/sync", json={"transactions": [fake.sign(appAccountToken=token)]}, headers=PLUS)
    assert synced.json()["is_plus"]
    return seeded_client


def trip(client, retailers, texts, headers=PLUS):
    body = {
        "store_ids": [store_id_for(client, r) for r in retailers],
        "items": [{"id": f"i{n}", "text": t} for n, t in enumerate(texts)],
    }
    return client.post("/route/multi", json=body, headers=headers)


def test_multi_store_needs_aisle_plus(seeded_client):
    refused = trip(seeded_client, ["Trader Joe's", "Home Depot"], ["milk"], headers={"X-Aisle-Device": "free"})
    assert refused.status_code == 402
    assert refused.json()["detail"]["feature"] == "multi_store"


def test_items_go_to_the_first_store_that_carries_them(plus):
    response = trip(plus, ["Trader Joe's", "Home Depot"], ["milk", "hammer", "bananas", "flux capacitor"])
    assert response.status_code == 200, response.text
    legs = response.json()["legs"]
    placed = {leg["retailer_name"]: {i["text"] for s in leg["stops"] for i in s["items"]} for leg in legs}
    assert placed["Trader Joe's"] == {"milk", "bananas"}
    assert placed["Home Depot"] == {"hammer"}
    # Legs keep the shopper's order, and something no store knows comes back once.
    assert [leg["retailer_name"] for leg in legs] == ["Trader Joe's", "Home Depot"]
    unplaced = [i["text"] for leg in legs for i in leg["unplaced"]] + [i["text"] for i in response.json()["unplaced"]]
    assert unplaced.count("flux capacitor") == 1


def test_stores_with_nothing_to_buy_are_skipped(plus):
    legs = trip(plus, ["Home Depot", "Trader Joe's"], ["milk", "bananas"]).json()["legs"]
    assert [leg["retailer_name"] for leg in legs] == ["Trader Joe's"]


def test_multi_store_validation(plus):
    tj = store_id_for(plus, "Trader Joe's")
    item = [{"id": "a", "text": "milk"}]
    assert plus.post("/route/multi", json={"store_ids": [tj], "items": item}, headers=PLUS).status_code == 422
    assert plus.post("/route/multi", json={"store_ids": [tj, tj], "items": item}, headers=PLUS).status_code == 422
    assert plus.post("/route/multi", json={"store_ids": [tj, 99999], "items": item}, headers=PLUS).status_code == 404
