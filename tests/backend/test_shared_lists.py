"""Shared family lists: sharing needs the owner's Aisle+, joining is free, and every
member's changes reach everyone."""
import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from backend.app.database import get_db
from backend.app.main import app
from backend.app.plus import appstore
from backend.app.routers.auth import get_phone_verifier
from test_plus import FakeApple


class AnyCode:
    def send(self, phone):
        pass

    def check(self, phone, code):
        return True


@pytest.fixture
def api(engine, monkeypatch):
    def override_db():
        with Session(engine) as session:
            yield session

    app.dependency_overrides[get_db] = override_db
    app.dependency_overrides[get_phone_verifier] = lambda: AnyCode()
    with TestClient(app) as client:
        yield client
    app.dependency_overrides.clear()


@pytest.fixture
def apple(monkeypatch):
    fake = FakeApple()
    monkeypatch.setattr(appstore, "apple_root", lambda: fake.root)
    return fake


def sign_in(api, phone, name):
    token = api.post("/auth/phone/verify", json={"phone": phone, "code": "123456"}).json()["token"]
    api.patch("/me", json={"first_name": name}, headers={"Authorization": f"Bearer {token}"})
    return {"Authorization": f"Bearer {token}", "X-Aisle-Device": f"device-{name}"}


def item(id, text, done=False, position=0):
    return {"id": id, "text": text, "is_done": done, "position": position}


@pytest.fixture
def family(api, apple):
    owner = sign_in(api, "2155550101", "Sam")
    member = sign_in(api, "2155550102", "Alex")
    token = api.get("/me", headers=owner).json()["plus_token"]
    api.post("/plus/sync", json={"transactions": [apple.sign(appAccountToken=token)]}, headers=owner)
    return owner, member


def test_sharing_needs_aisle_plus_and_signing_in(api):
    free = sign_in(api, "2155550103", "Jo")
    refused = api.post("/lists", json={"name": "Groceries"}, headers=free)
    assert refused.status_code == 402
    assert refused.json()["detail"]["feature"] == "shared_lists"
    assert api.post("/lists", json={"name": "Groceries"}).status_code == 401


def test_share_join_and_sync(api, family):
    owner, member = family
    shared = api.post("/lists", json={"name": "Groceries", "items": [item("a", "milk"), item("b", "eggs", position=1)]},
                      headers=owner)
    assert shared.status_code == 201
    body = shared.json()
    code, list_id = body["invite_code"], body["id"]
    assert len(code) == 6 and body["is_owner"] is True
    assert [i["text"] for i in body["items"]] == ["milk", "eggs"]

    # Joining is free, and codes forgive case and spacing.
    joined = api.post("/lists/join", json={"code": f" {code[:3].lower()} {code[3:]} "}, headers=member)
    assert joined.status_code == 200
    assert joined.json()["is_owner"] is False
    assert [(m["first_name"], m["is_owner"]) for m in joined.json()["members"]] == [("Sam", True), ("Alex", False)]

    version = joined.json()["version"]
    changed = api.post(f"/lists/{list_id}/changes", json={"changes": [
        {"op": "upsert", "item": item("a", "milk", done=True)},
        {"op": "upsert", "item": item("c", "bread", position=2)},
        {"op": "delete", "id": "b"},
    ]}, headers=member).json()
    assert changed["version"] == version + 1

    seen = api.get(f"/lists/{list_id}", headers=owner).json()
    assert [(i["text"], i["is_done"]) for i in seen["items"]] == [("milk", True), ("bread", False)]
    assert [s["item_count"] for s in api.get("/lists", headers=member).json()] == [2]


def test_rename_leave_and_delete(api, family):
    owner, member = family
    shared = api.post("/lists", json={"name": "Groceries"}, headers=owner).json()
    api.post("/lists/join", json={"code": shared["invite_code"]}, headers=member)
    assert api.patch(f"/lists/{shared['id']}", json={"name": "Weekend"}, headers=member).json()["name"] == "Weekend"

    assert api.delete(f"/lists/{shared['id']}", headers=member).status_code == 204
    assert api.get(f"/lists/{shared['id']}", headers=member).status_code == 404
    assert len(api.get(f"/lists/{shared['id']}", headers=owner).json()["members"]) == 1

    api.post("/lists/join", json={"code": shared["invite_code"]}, headers=member)
    assert api.delete(f"/lists/{shared['id']}", headers=owner).status_code == 204
    assert api.get(f"/lists/{shared['id']}", headers=member).status_code == 404
    assert api.get("/lists", headers=member).json() == []


def test_strangers_and_bad_codes(api, family):
    owner, _ = family
    stranger = sign_in(api, "2155550109", "Pat")
    shared = api.post("/lists", json={"name": "Groceries", "items": [item("a", "milk")]}, headers=owner).json()
    assert api.get(f"/lists/{shared['id']}", headers=stranger).status_code == 404
    assert api.post(f"/lists/{shared['id']}/changes", json={"changes": []}, headers=stranger).status_code == 404
    assert api.post("/lists/join", json={"code": "ZZZZZZ"}, headers=stranger).status_code == 404


def test_items_cant_move_between_lists(api, family):
    owner, _ = family
    first = api.post("/lists", json={"name": "A", "items": [item("same-id", "milk")]}, headers=owner).json()
    second = api.post("/lists", json={"name": "B"}, headers=owner).json()
    api.post(f"/lists/{second['id']}/changes", json={"changes": [{"op": "upsert", "item": item("same-id", "hijack")}]},
             headers=owner)
    assert api.get(f"/lists/{first['id']}", headers=owner).json()["items"][0]["text"] == "milk"
    assert api.get(f"/lists/{second['id']}", headers=owner).json()["items"] == []
