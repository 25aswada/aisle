"""Shared family lists: sharing needs the owner's Aisle+, joining is free, and every
member's changes reach everyone."""
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from backend.app.database import get_db
from backend.app.main import app
from backend.app.models import PlusEntitlement, SharedListMember, User
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
    assert len(code) == 8 and body["is_owner"] is True
    assert [i["text"] for i in body["items"]] == ["milk", "eggs"]

    # Joining is free, and codes forgive case and spacing.
    joined = api.post("/lists/join", json={"code": f" {code[:4].lower()} {code[4:]} "}, headers=member)
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
    assert api.patch(f"/lists/{shared['id']}", json={"name": "Weekend"}, headers=owner).json()["name"] == "Weekend"
    assert api.get(f"/lists/{shared['id']}", headers=member).json()["name"] == "Weekend"

    # Leaving isn't being removed: the code still works afterwards.
    assert api.delete(f"/lists/{shared['id']}", headers=member).status_code == 204
    assert api.get(f"/lists/{shared['id']}", headers=member).status_code == 404
    assert len(api.get(f"/lists/{shared['id']}", headers=owner).json()["members"]) == 1

    assert api.post("/lists/join", json={"code": shared["invite_code"]}, headers=member).status_code == 200
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


def test_the_same_item_id_on_two_lists_is_two_items(api, family):
    owner, _ = family
    first = api.post("/lists", json={"name": "A", "items": [item("same-id", "milk")]}, headers=owner).json()
    second = api.post("/lists", json={"name": "B", "items": [item("same-id", "nails")]}, headers=owner)
    assert second.status_code == 201
    second = second.json()
    changed = api.post(f"/lists/{second['id']}/changes", json={"changes": [
        {"op": "upsert", "item": item("same-id", "screws")}, {"op": "upsert", "item": item("other", "glue")},
    ]}, headers=owner)
    assert changed.status_code == 200
    assert api.get(f"/lists/{first['id']}", headers=owner).json()["items"][0]["text"] == "milk"
    assert [i["text"] for i in changed.json()["items"]] == ["screws", "glue"]

    # Deleting it from one list leaves the other alone.
    api.post(f"/lists/{second['id']}/changes", json={"changes": [{"op": "delete", "id": "same-id"}]}, headers=owner)
    assert [i["text"] for i in api.get(f"/lists/{first['id']}", headers=owner).json()["items"]] == ["milk"]
    assert [i["text"] for i in api.get(f"/lists/{second['id']}", headers=owner).json()["items"]] == ["glue"]


def test_guessing_invite_codes_is_cut_off(api, family):
    _, member = family
    statuses = [api.post("/lists/join", json={"code": f"ZZZZZ{n:03d}"}, headers=member).status_code
                for n in range(21)]
    assert statuses == [404] * 20 + [429]


def test_a_list_holds_up_to_20_people(api, family, engine):
    owner, member = family
    shared = api.post("/lists", json={"name": "Groceries"}, headers=owner).json()
    with Session(engine) as db:
        for _ in range(19):
            someone = User()
            db.add(someone)
            db.flush()
            db.add(SharedListMember(list_id=shared["id"], user_id=someone.id))
        db.commit()
    full = api.post("/lists/join", json={"code": shared["invite_code"]}, headers=member)
    assert full.status_code == 409 and "20 people" in full.json()["detail"]


def test_no_one_new_joins_once_the_owners_aisle_plus_ends(api, family, engine):
    owner, member = family
    shared = api.post("/lists", json={"name": "Groceries"}, headers=owner).json()
    with Session(engine) as db:
        db.query(PlusEntitlement).update({PlusEntitlement.expires_at: datetime.now(timezone.utc) - timedelta(days=1)})
        db.commit()
    refused = api.post("/lists/join", json={"code": shared["invite_code"]}, headers=member)
    assert refused.status_code == 403 and "renew" in refused.json()["detail"]
    # The owner still has the list.
    assert api.get(f"/lists/{shared['id']}", headers=owner).status_code == 200


# MARK: - The owner's controls, reports and limits

class FakeMail:
    def __init__(self, fails=False):
        self.sent = []
        self.fails = fails

    def send_text(self, email, subject, text):
        if self.fails:
            raise ConnectionError("Resend unreachable")
        self.sent.append((email, subject, text))


def member_id(listing, first_name):
    return next(m["id"] for m in listing["members"] if m["first_name"] == first_name)


def test_only_the_owner_sees_the_invite_code(api, family):
    owner, member = family
    shared = api.post("/lists", json={"name": "Groceries"}, headers=owner).json()
    joined = api.post("/lists/join", json={"code": shared["invite_code"]}, headers=member).json()
    assert joined["invite_code"] is None
    assert api.get(f"/lists/{shared['id']}", headers=member).json()["invite_code"] is None
    assert api.get(f"/lists/{shared['id']}", headers=owner).json()["invite_code"] == shared["invite_code"]


def test_a_new_invite_code_retires_the_old_one(api, family):
    owner, member = family
    stranger = sign_in(api, "2155550109", "Pat")
    shared = api.post("/lists", json={"name": "Groceries"}, headers=owner).json()
    api.post("/lists/join", json={"code": shared["invite_code"]}, headers=member)
    assert api.post(f"/lists/{shared['id']}/code", headers=member).status_code == 403

    rotated = api.post(f"/lists/{shared['id']}/code", headers=owner).json()
    assert rotated["invite_code"] != shared["invite_code"] and len(rotated["invite_code"]) == 8
    assert api.post("/lists/join", json={"code": shared["invite_code"]}, headers=stranger).status_code == 404
    assert api.post("/lists/join", json={"code": rotated["invite_code"]}, headers=stranger).status_code == 200
    # Nobody already on it was removed.
    assert len(api.get(f"/lists/{shared['id']}", headers=owner).json()["members"]) == 3


def test_someone_the_owner_removes_cant_join_again(api, family):
    owner, member = family
    third = sign_in(api, "2155550109", "Pat")
    shared = api.post("/lists", json={"name": "Groceries"}, headers=owner).json()
    for person in (member, third):
        api.post("/lists/join", json={"code": shared["invite_code"]}, headers=person)
    listing = api.get(f"/lists/{shared['id']}", headers=owner).json()

    # Only the owner removes people, and not themselves.
    assert api.delete(f"/lists/{shared['id']}/members/{member_id(listing, 'Pat')}", headers=member).status_code == 403
    assert api.delete(f"/lists/{shared['id']}/members/{member_id(listing, 'Sam')}", headers=owner).status_code == 400
    assert api.delete(f"/lists/{shared['id']}/members/999999", headers=owner).status_code == 404

    removed = api.delete(f"/lists/{shared['id']}/members/{member_id(listing, 'Alex')}", headers=owner)
    assert removed.status_code == 200
    assert [m["first_name"] for m in removed.json()["members"]] == ["Sam", "Pat"]
    assert api.get(f"/lists/{shared['id']}", headers=member).status_code == 404

    refused = api.post("/lists/join", json={"code": shared["invite_code"]}, headers=member)
    assert refused.status_code == 403 and refused.json()["detail"] == "You can't join this list."
    # The ban outlives the code.
    rotated = api.post(f"/lists/{shared['id']}/code", headers=owner).json()["invite_code"]
    assert api.post("/lists/join", json={"code": rotated}, headers=member).status_code == 403


def test_only_the_owner_renames(api, family):
    owner, member = family
    shared = api.post("/lists", json={"name": "Groceries"}, headers=owner).json()
    api.post("/lists/join", json={"code": shared["invite_code"]}, headers=member)
    refused = api.patch(f"/lists/{shared['id']}", json={"name": "Mine now"}, headers=member)
    assert refused.status_code == 403 and "owner" in refused.json()["detail"]
    assert api.get(f"/lists/{shared['id']}", headers=owner).json()["name"] == "Groceries"


def test_a_report_is_kept_and_emailed_to_support(api, family, engine):
    from backend.app.legal import CONTACT_EMAIL
    from backend.app.models import ContentReport
    from backend.app.routers.shared_lists import get_report_sender

    owner, member = family
    mail = FakeMail()
    app.dependency_overrides[get_report_sender] = lambda: mail
    shared = api.post("/lists", json={"name": "Groceries", "items": [item("a", "something rude")]}, headers=owner).json()
    api.post("/lists/join", json={"code": shared["invite_code"]}, headers=member)
    stranger = sign_in(api, "2155550109", "Pat")
    assert api.post(f"/lists/{shared['id']}/report", json={"reason": "spam"}, headers=stranger).status_code == 404
    assert api.post(f"/lists/{shared['id']}/report", json={"reason": "rude"}, headers=member).status_code == 422

    reported = api.post(f"/lists/{shared['id']}/report",
                        json={"reason": "harassment", "note": " Not from my family ", "leave": True}, headers=member)
    assert reported.status_code == 204
    with Session(engine) as db:
        report = db.query(ContentReport).one()
        assert (report.reason, report.note, report.list_id) == ("harassment", "Not from my family", shared["id"])
        assert report.snapshot["name"] == "Groceries" and report.snapshot["items"] == ["something rude"]
        assert report.reporter_id is not None and report.emailed_at is not None and report.created_at is not None
    [(to, subject, text)] = mail.sent
    assert to == CONTACT_EMAIL and "harassment" in subject and "something rude" in text
    # They asked to leave, too.
    assert api.get(f"/lists/{shared['id']}", headers=member).status_code == 404


@pytest.mark.parametrize("mail", [None, FakeMail(fails=True)])
def test_a_report_is_kept_when_email_cant_send(api, family, engine, mail):
    from backend.app.models import ContentReport
    from backend.app.routers.shared_lists import get_report_sender

    owner, member = family
    app.dependency_overrides[get_report_sender] = lambda: mail
    shared = api.post("/lists", json={"name": "Groceries"}, headers=owner).json()
    api.post("/lists/join", json={"code": shared["invite_code"]}, headers=member)
    assert api.post(f"/lists/{shared['id']}/report", json={"reason": "other"}, headers=member).status_code == 204
    with Session(engine) as db:
        report = db.query(ContentReport).one()
        assert report.emailed_at is None and report.note is None
    # Reporting alone doesn't leave the list.
    assert api.get(f"/lists/{shared['id']}", headers=member).status_code == 200


def test_list_writes_are_rate_limited(api, family, monkeypatch):
    from backend.app.config import get_settings
    from backend.app.routers import shared_lists

    owner, member = family
    app.dependency_overrides[shared_lists.get_report_sender] = lambda: None
    monkeypatch.setattr(get_settings(), "aisle_list_changes_per_hour", 3)
    monkeypatch.setattr(get_settings(), "aisle_writes_per_hour", 2)
    monkeypatch.setattr(shared_lists, "REPORTS_PER_HOUR", 2)
    shared = api.post("/lists", json={"name": "Groceries"}, headers=owner).json()
    api.post("/lists/join", json={"code": shared["invite_code"]}, headers=member)
    url = f"/lists/{shared['id']}"

    changes = [api.post(f"{url}/changes", json={"changes": []}, headers=member).status_code for _ in range(4)]
    assert changes == [200, 200, 200, 429]
    # Renaming and new codes share one limit.
    settings = [api.patch(url, json={"name": "Weekend"}, headers=owner).status_code,
                api.post(f"{url}/code", headers=owner).status_code,
                api.patch(url, json={"name": "Again"}, headers=owner).status_code]
    assert settings == [200, 200, 429]
    reports = [api.post(f"{url}/report", json={"reason": "spam"}, headers=member).status_code for _ in range(3)]
    assert reports == [204, 204, 429]


def test_changes_come_100_at_a_time(api, family):
    owner, _ = family
    shared = api.post("/lists", json={"name": "Groceries"}, headers=owner).json()
    many = [{"op": "upsert", "item": item(f"i{n}", f"thing {n}", position=n)} for n in range(101)]
    assert api.post(f"/lists/{shared['id']}/changes", json={"changes": many}, headers=owner).status_code == 422
    assert api.post(f"/lists/{shared['id']}/changes", json={"changes": many[:100]}, headers=owner).status_code == 200


def test_deleting_the_owners_account_hands_the_list_on(api, family):
    owner, member = family
    third = sign_in(api, "2155550109", "Pat")
    shared = api.post("/lists", json={"name": "Groceries", "items": [item("a", "milk")]}, headers=owner).json()
    alone = api.post("/lists", json={"name": "Just me"}, headers=owner).json()
    for person in (member, third):
        api.post("/lists/join", json={"code": shared["invite_code"]}, headers=person)

    assert api.delete("/me", headers=owner).status_code == 204
    # Alex joined first, so the list is theirs now, items and all.
    taken = api.get(f"/lists/{shared['id']}", headers=member).json()
    assert taken["is_owner"] is True and taken["invite_code"] == shared["invite_code"]
    assert [i["text"] for i in taken["items"]] == ["milk"]
    assert [(m["first_name"], m["is_owner"]) for m in taken["members"]] == [("Alex", True), ("Pat", False)]
    assert api.get(f"/lists/{shared['id']}", headers=third).json()["is_owner"] is False
    assert api.patch(f"/lists/{shared['id']}", json={"name": "Ours"}, headers=member).status_code == 200
    # A list with nobody else on it goes with the account.
    assert api.post("/lists/join", json={"code": alone["invite_code"]}, headers=third).status_code == 404

    # Someone who isn't the owner deleting their account just leaves.
    assert api.delete("/me", headers=third).status_code == 204
    assert [m["first_name"] for m in api.get(f"/lists/{shared['id']}", headers=member).json()["members"]] == ["Alex"]
