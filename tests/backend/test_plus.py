"""Aisle+: verifying App Store transactions, and the free tier's daily limits.

A fake Apple chain (root, intermediate, leaf with Apple's marker extensions) signs
transactions here, so the real verification code runs end to end.
"""
import base64
import json
import time
from datetime import datetime, timedelta, timezone

import jwt
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from backend.app.ai import budget
from backend.app.ai.providers import get_explainer, get_location_model
from backend.app.config import get_settings
from backend.app.database import get_db
from backend.app.main import app
from backend.app.auth.accounts import create_session, sign_in
from backend.app.models import PlusEntitlement, Retailer, Store, UsageCounter, User
from backend.app.plus import appstore
from backend.app.plus.appstore import INTERMEDIATE_OID, LEAF_OID, InvalidTransaction, verify_transaction

BUNDLE = "app.shopaisle.aisle"
YEARLY = "app.shopaisle.plus.yearly"
PRODUCTS = {YEARLY, "app.shopaisle.plus.monthly"}
PHOTO = base64.b64encode(b"\xff\xd8\xff\xe0 a photo").decode()


def _cert(subject, key, issuer=None, issuer_key=None, ca=False, oid=None, days=365):
    now = datetime.now(timezone.utc)
    builder = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject)]))
        .issuer_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, issuer or subject)]))
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=10))
        .not_valid_after(now + timedelta(days=days))
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
    )
    if oid is not None:
        builder = builder.add_extension(x509.UnrecognizedExtension(oid, b"\x05\x00"), critical=False)
    return builder.sign(issuer_key or key, hashes.SHA384() if ca else hashes.SHA256())


class FakeApple:
    def __init__(self, leaf_oid=LEAF_OID, leaf_days=365):
        self.root_key = ec.generate_private_key(ec.SECP384R1())
        self.root = _cert("Fake Root", self.root_key, ca=True)
        inter_key = ec.generate_private_key(ec.SECP384R1())
        self.intermediate = _cert("Fake WWDR", inter_key, "Fake Root", self.root_key, ca=True, oid=INTERMEDIATE_OID)
        self.leaf_key = ec.generate_private_key(ec.SECP256R1())
        self.leaf = _cert("Fake Leaf", self.leaf_key, "Fake WWDR", inter_key, oid=leaf_oid, days=leaf_days)

    def sign(self, **overrides):
        now_ms = int(time.time() * 1000)
        payload = {
            "transactionId": "2000000001", "originalTransactionId": "1000000001", "bundleId": BUNDLE,
            "productId": YEARLY, "expiresDate": now_ms + 7 * 86_400_000, "environment": "Sandbox",
            "signedDate": now_ms, "purchaseDate": now_ms,
        }
        payload.update(overrides)
        x5c = [base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode()
               for c in (self.leaf, self.intermediate, self.root)]
        return jwt.PyJWS().encode(json.dumps(payload).encode(), self.leaf_key, algorithm="ES256",
                                  headers={"x5c": x5c})


@pytest.fixture
def apple(monkeypatch):
    fake = FakeApple()
    monkeypatch.setattr(appstore, "apple_root", lambda: fake.root)
    return fake


# MARK: - Verifying transactions

def test_a_genuine_transaction_verifies(apple):
    verified = verify_transaction(apple.sign(), bundle_id=BUNDLE, product_ids=PRODUCTS)
    assert verified.original_transaction_id == "1000000001"
    assert verified.product_id == YEARLY
    assert verified.expires_at > datetime.now(timezone.utc)
    assert verified.environment == "Sandbox"


def test_the_real_apple_root_is_pinned():
    root = appstore.apple_root()
    assert root.fingerprint(hashes.SHA256()).hex() == (
        "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179")


def test_forgeries_are_rejected(apple):
    other_app = apple.sign(bundleId="com.someone.else")
    other_product = apple.sign(productId="com.someone.coins")
    header, payload, signature = apple.sign().split(".")
    tampered_payload = base64.urlsafe_b64encode(json.dumps({
        "transactionId": "1", "originalTransactionId": "1", "bundleId": BUNDLE, "productId": YEARLY,
        "expiresDate": 99999999999999, "environment": "Sandbox",
    }).encode()).decode().rstrip("=")
    tampered = f"{header}.{tampered_payload}.{signature}"
    for jws in [other_app, other_product, tampered, "nonsense", "a.b.c"]:
        with pytest.raises(InvalidTransaction):
            verify_transaction(jws, bundle_id=BUNDLE, product_ids=PRODUCTS)


def test_a_chain_from_another_root_is_rejected(monkeypatch):
    signer = FakeApple()
    monkeypatch.setattr(appstore, "apple_root", lambda: FakeApple().root)
    with pytest.raises(InvalidTransaction):
        verify_transaction(signer.sign(), bundle_id=BUNDLE, product_ids=PRODUCTS)


def test_certificates_must_be_apples_and_current(monkeypatch):
    for fake in (FakeApple(leaf_oid=None), FakeApple(leaf_days=-2)):
        monkeypatch.setattr(appstore, "apple_root", lambda fake=fake: fake.root)
        with pytest.raises(InvalidTransaction):
            verify_transaction(fake.sign(), bundle_id=BUNDLE, product_ids=PRODUCTS)


def test_xcode_test_purchases_only_when_allowed(apple):
    xcode = apple.sign(environment="Xcode")
    with pytest.raises(InvalidTransaction):
        verify_transaction(xcode, bundle_id=BUNDLE, product_ids=PRODUCTS)
    assert verify_transaction(xcode, bundle_id=BUNDLE, product_ids=PRODUCTS, allow_xcode=True).environment == "Xcode"


# MARK: - Endpoints and limits

class FakeAI:
    """Identifies every photo as milk and answers every follow-up."""

    def explain(self, facts):
        return None

    def chat(self, system, messages):
        return "NONE" if "decide whether" in system else ("milk" if "search phrase" in system else "It's by the eggs.")


@pytest.fixture
def api(engine, apple):
    with Session(engine) as db:
        retailer = Retailer(name="Costco")
        db.add(retailer)
        db.flush()
        db.add(Store(retailer_id=retailer.id, name="Costco KOP", address="1 Mall Rd", latitude=40, longitude=-75))
        db.commit()

    def override_db():
        with Session(engine) as session:
            yield session

    app.dependency_overrides[get_db] = override_db
    app.dependency_overrides[get_explainer] = lambda: FakeAI()
    with TestClient(app) as client:
        client.engine, client.shoppers = engine, {}
        yield client
    app.dependency_overrides.clear()


def device(name):
    return {"X-Aisle-Device": name}


def shopper(api, name):
    """A signed-in shopper's headers, the same for each name within a test."""
    if name not in api.shoppers:
        api.shoppers[name] = account(api.engine, name)[0]
    return api.shoppers[name]


def identify(api, who):
    return api.post("/identify", json={"image": PHOTO}, headers=shopper(api, who))


def test_free_photo_searches_stop_at_the_daily_limit(api):
    assert identify(api, "phone-a").json() == {"item": "milk"}
    blocked = identify(api, "phone-a")
    assert blocked.status_code == 402
    assert blocked.json()["detail"]["code"] == "plus_required"
    assert blocked.json()["detail"]["feature"] == "photo_search"
    assert blocked.json()["detail"]["message"] == "You've used today's free photo search. Aisle+ has unlimited."
    # Another account has its own allowance; list scans share the same one.
    assert identify(api, "phone-b").status_code == 200
    assert api.post("/lists/scan", json={"image": PHOTO}, headers=shopper(api, "phone-a")).status_code == 402

    status = api.get("/plus/status", headers=shopper(api, "phone-a")).json()
    assert status["is_plus"] is False
    assert status["photo_search"] == {"used": 1, "limit": 1}


def test_limits_reset_each_day(api, engine):
    for _ in range(3):
        identify(api, "phone-a")
    with Session(engine) as db:
        for counter in db.query(UsageCounter):
            counter.day = "2000-01-01"
        db.commit()
    assert identify(api, "phone-a").status_code == 200


def test_follow_ups_have_their_own_limit_and_photos_count_as_photo_searches(api):
    convo = [{"role": "user", "content": "milk"}, {"role": "assistant", "content": "Dairy."},
             {"role": "user", "content": "and eggs?"}]
    for _ in range(5):
        assert api.post("/chat", json={"store_id": 1, "messages": convo}, headers=shopper(api, "p")).status_code == 200
    assert api.post("/chat", json={"store_id": 1, "messages": convo}, headers=shopper(api, "p")).status_code == 402
    with_photo = convo[:2] + [{"role": "user", "content": "this?", "image": PHOTO}]
    assert api.post("/chat", json={"store_id": 1, "messages": with_photo}, headers=shopper(api, "p")).status_code == 200
    status = api.get("/plus/status", headers=shopper(api, "p")).json()
    assert status["follow_up"]["used"] == 5 and status["photo_search"]["used"] == 1


def account(engine, device_id="phone-a"):
    """A signed-in shopper: request headers and the token StoreKit stamps on their purchases."""
    with Session(engine) as db:
        user = User()
        db.add(user)
        db.commit()
        token = create_session(db, user, device_id)
        return {"Authorization": f"Bearer {token}", **device(device_id)}, user.plus_token, user.id


def sync(api, headers, *transactions, claim=False):
    return api.post("/plus/sync", json={"transactions": list(transactions), "claim": claim}, headers=headers)


def test_a_verified_subscription_lifts_the_limits(api, apple, engine):
    headers, token, _ = account(engine)
    for _ in range(3):
        api.post("/identify", json={"image": PHOTO}, headers=headers)  # One allowed, then 402s.
    synced = sync(api, headers, apple.sign(appAccountToken=token.upper()))
    assert synced.status_code == 200
    assert synced.json()["is_plus"] is True
    for _ in range(3):
        assert api.post("/identify", json={"image": PHOTO}, headers=headers).status_code == 200
    # Aisle+ use isn't counted against the free tier.
    assert api.get("/plus/status", headers=headers).json()["photo_search"]["used"] == 1


def test_aisle_plus_needs_an_account(api, apple):
    # Signed out, even a genuine subscription doesn't unlock anything.
    synced = sync(api, device("phone-a"), apple.sign())
    assert synced.status_code == 200 and synced.json()["is_plus"] is False


def test_a_subscription_belongs_to_the_account_that_bought_it(api, apple, engine):
    owner, token, _ = account(engine, "phone-a")
    other, _, _ = account(engine, "phone-a")
    bought = apple.sign(appAccountToken=token)
    assert sync(api, owner, bought).json()["is_plus"] is True
    # Another account on the same phone and Apple ID doesn't get it, even by restoring.
    assert sync(api, other, bought).json()["is_plus"] is False
    assert sync(api, other, bought, claim=True).json()["is_plus"] is False
    assert api.get("/plus/status", headers=other).json()["is_plus"] is False
    # A purchase made for no account only moves over when restoring.
    unstamped = apple.sign(originalTransactionId="1000000002")
    assert sync(api, other, unstamped).json()["is_plus"] is False
    assert sync(api, other, unstamped, claim=True).json()["is_plus"] is True


def test_deleting_the_account_ends_aisle_plus_and_resets_the_free_tier(api, apple, engine):
    headers, token, user_id = account(engine)
    bought = apple.sign(appAccountToken=token)
    assert sync(api, headers, bought).json()["is_plus"] is True
    with Session(engine) as db:
        db.add(UsageCounter(subject=f"user:{user_id}", feature="photo_search", day="2026-10-04", count=5))
        db.commit()
    assert api.delete("/me", headers=headers).status_code == 204
    with Session(engine) as db:
        assert db.query(PlusEntitlement).count() == 0
        assert db.query(UsageCounter).filter_by(subject=f"user:{user_id}").count() == 0

    # Someone else's new account starts on the free tier with nothing used, even with
    # Apple still billing.
    fresh, _, _ = account(engine)
    status = sync(api, fresh, bought).json()
    assert status["is_plus"] is False
    assert status["photo_search"]["used"] == 0
    # "Restore purchases" can move the still-billed subscription to the new account.
    assert sync(api, fresh, bought, claim=True).json()["is_plus"] is True


def test_expired_or_refunded_subscriptions_dont_count(api, apple, engine):
    headers, token, _ = account(engine)
    past = int(time.time() * 1000) - 1000
    assert sync(api, headers, apple.sign(expiresDate=past, appAccountToken=token)).json()["is_plus"] is False
    refunded = apple.sign(originalTransactionId="77", revocationDate=past, appAccountToken=token)
    assert sync(api, headers, refunded).json()["is_plus"] is False


def test_unverifiable_purchases_are_refused(api):
    refused = api.post("/plus/sync", json={"transactions": ["a.b.c"]}, headers=device("a"))
    assert refused.status_code == 400
    assert api.post("/plus/sync", json={"transactions": []}, headers=device("a")).json()["is_plus"] is False


def test_xcode_purchases_follow_the_setting(api, apple, monkeypatch, engine):
    headers, token, _ = account(engine)
    monkeypatch.setattr(get_settings(), "aisle_plus_allow_xcode", False)
    xcode = apple.sign(environment="Xcode", originalTransactionId="55", appAccountToken=token)
    assert sync(api, headers, xcode).status_code == 400
    monkeypatch.setattr(get_settings(), "aisle_plus_allow_xcode", True)
    assert sync(api, headers, xcode).json()["is_plus"] is True


# MARK: - App Store Server Notifications

def notify(api, apple, notification_type, transaction, bundle=BUNDLE):
    signed = apple.sign(notificationType=notification_type,
                        data={"bundleId": bundle, "environment": "Sandbox", "signedTransactionInfo": transaction})
    return api.post("/plus/notifications", json={"signedPayload": signed})


def test_a_refund_notification_ends_aisle_plus(api, apple, engine):
    headers, token, _ = account(engine)
    bought = apple.sign(appAccountToken=token)
    assert sync(api, headers, bought).json()["is_plus"] is True
    past = int(time.time() * 1000) - 1000
    assert notify(api, apple, "REFUND", apple.sign(appAccountToken=token, revocationDate=past)).status_code == 200
    assert api.get("/plus/status", headers=headers).json()["is_plus"] is False


def test_a_renewal_notification_reaches_an_account_that_never_synced(api, apple, engine):
    headers, token, _ = account(engine)
    later = int(time.time() * 1000) + 30 * 86_400_000
    assert notify(api, apple, "DID_RENEW", apple.sign(appAccountToken=token, expiresDate=later)).status_code == 200
    assert api.get("/plus/status", headers=headers).json()["is_plus"] is True


def test_an_older_transaction_cant_shorten_a_subscription(api, apple, engine):
    headers, token, _ = account(engine)
    later = int(time.time() * 1000) + 30 * 86_400_000
    sync(api, headers, apple.sign(appAccountToken=token, expiresDate=later))
    sync(api, headers, apple.sign(appAccountToken=token, expiresDate=int(time.time() * 1000) - 1000))
    assert api.get("/plus/status", headers=headers).json()["is_plus"] is True


def test_notifications_must_be_genuine_and_for_this_app(api, apple):
    assert api.post("/plus/notifications", json={"signedPayload": "a.b.c" + "x" * 20}).status_code == 400
    assert notify(api, apple, "DID_RENEW", apple.sign(), bundle="com.other.app").status_code == 400
    forged = FakeApple()  # Signed by someone else's certificates.
    assert notify(api, forged, "REFUND", forged.sign()).status_code == 400


def test_a_refunded_subscription_stays_refunded(api, apple, engine):
    headers, token, _ = account(engine)
    now_ms = int(time.time() * 1000)
    bought = apple.sign(appAccountToken=token, expiresDate=now_ms + 365 * 86_400_000, purchaseDate=now_ms - 60_000)
    assert sync(api, headers, bought).json()["is_plus"] is True
    refunded = apple.sign(appAccountToken=token, expiresDate=now_ms + 365 * 86_400_000,
                          purchaseDate=now_ms - 60_000, revocationDate=now_ms)
    assert notify(api, apple, "REFUND", refunded).status_code == 200
    # Sending the purchase saved from before the refund doesn't bring Aisle+ back...
    assert sync(api, headers, bought).json()["is_plus"] is False
    assert sync(api, headers, bought, claim=True).json()["is_plus"] is False
    # ...but subscribing again does, even for a shorter plan.
    again = apple.sign(appAccountToken=token, transactionId="2000000002", productId="app.shopaisle.plus.monthly",
                       expiresDate=now_ms + 30 * 86_400_000, purchaseDate=now_ms + 1000)
    assert sync(api, headers, again).json()["is_plus"] is True


def test_apple_reversing_a_refund_restores_aisle_plus(api, apple, engine):
    headers, token, _ = account(engine)
    now_ms = int(time.time() * 1000)
    bought = apple.sign(appAccountToken=token, purchaseDate=now_ms - 60_000)
    sync(api, headers, bought)
    notify(api, apple, "REFUND", apple.sign(appAccountToken=token, purchaseDate=now_ms - 60_000, revocationDate=now_ms))
    assert api.get("/plus/status", headers=headers).json()["is_plus"] is False
    assert notify(api, apple, "REFUND_REVERSED", bought).status_code == 200
    assert api.get("/plus/status", headers=headers).json()["is_plus"] is True


def signed_in_as(engine, provider, subject, email=None):
    """Signs in the way the app would (outside a request, so no per-network account limit)."""
    with Session(engine) as db:
        user, _ = sign_in(db, provider, subject, email=email, email_verified=email is not None)
        return {"Authorization": f"Bearer {create_session(db, user, 'phone-a')}"}


def test_deleting_the_account_and_signing_up_again_doesnt_reset_the_free_tier(api, engine):
    headers = signed_in_as(engine, "apple", "apple-sub-1", "sam@example.com")
    assert api.post("/identify", json={"image": PHOTO}, headers=headers).status_code == 200
    assert api.delete("/me", headers=headers).status_code == 204
    # Same Apple ID, or any other way the account signed in (here its email), picks up
    # where it left off.
    for provider, subject in (("apple", "apple-sub-1"), ("email", "sam@example.com")):
        again = signed_in_as(engine, provider, subject, "sam@example.com" if provider == "email" else None)
        assert api.get("/plus/status", headers=again).json()["photo_search"]["used"] == 1
        assert api.post("/identify", json={"image": PHOTO}, headers=again).status_code == 402
        api.delete("/me", headers=again)
    # A different person starts fresh.
    other = signed_in_as(engine, "apple", "apple-sub-2")
    assert api.post("/identify", json={"image": PHOTO}, headers=other).status_code == 200


class RecordingAI(FakeAI):
    def __init__(self, explanation=None):
        self.chats, self.explanation = [], explanation

    def explain(self, facts):
        return self.explanation

    def chat(self, system, messages):
        self.chats.append(messages)
        return super().chat(system, messages)


def test_photos_earlier_in_a_follow_up_go_nowhere(api, engine, monkeypatch):
    monkeypatch.setattr(get_settings(), "aisle_free_follow_ups_per_search", 10)
    ai = RecordingAI()
    app.dependency_overrides[get_explainer] = lambda: ai
    headers, _, _ = account(engine)
    convo = [
        {"role": "user", "content": "this?", "image": PHOTO}, {"role": "assistant", "content": "made up"},
        {"role": "user", "content": "", "image": PHOTO}, {"role": "assistant", "content": "made up"},
        {"role": "user", "content": "what are these two things?"},
    ]
    assert api.post("/chat", json={"store_id": 1, "messages": convo}, headers=headers).status_code == 200
    # A text follow-up, so its photos never reach the AI.
    assert all("image" not in m for m in ai.chats[0])
    assert [m["content"] for m in ai.chats[0]][2] == "(a photo)"
    status = api.get("/plus/status", headers=headers).json()
    assert status["photo_search"]["used"] == 0 and status["follow_up"]["used"] == 1


def test_long_conversations_are_trimmed_before_the_ai(api, engine, monkeypatch):
    monkeypatch.setattr(get_settings(), "aisle_free_follow_ups_per_search", 100)
    ai = RecordingAI()
    app.dependency_overrides[get_explainer] = lambda: ai
    headers, _, _ = account(engine)
    convo = [{"role": "user" if i % 2 == 0 else "assistant", "content": f"{i} " + "x" * 3990} for i in range(39)]
    assert api.post("/chat", json={"store_id": 1, "messages": convo}, headers=headers).status_code == 200
    sent = ai.chats[0]
    assert len(sent) == 11
    assert [m["content"].split()[0] for m in sent] == ["0", "1", *map(str, range(30, 39))]
    assert all(len(m["content"]) <= 2000 for m in sent)


def search(api, headers=None):
    return api.post("/search", json={"query": "milk", "store_id": 1}, headers=headers or {})


def test_free_searches_stop_at_the_daily_limit_and_aisle_plus_lifts_it(api, apple, engine):
    headers, token, _ = account(engine)
    assert [search(api, headers).status_code for _ in range(5)] == [200] * 5
    blocked = search(api, headers)
    assert blocked.status_code == 402
    assert blocked.json()["detail"]["feature"] == "search"
    assert blocked.json()["detail"]["message"] == "You've used today's 5 free searches. Aisle+ has unlimited."
    assert api.get("/plus/status", headers=headers).json()["search"] == {"used": 5, "limit": 5}
    # A store that doesn't exist doesn't use one up.
    other, _, _ = account(engine, "phone-b")
    assert api.post("/search", json={"query": "milk", "store_id": 999}, headers=other).status_code == 404
    assert api.get("/plus/status", headers=other).json()["search"]["used"] == 0
    # Aisle+ searches aren't limited (or counted against the free tier).
    sync(api, headers, apple.sign(appAccountToken=token))
    assert search(api, headers).status_code == 200
    assert api.get("/plus/status", headers=headers).json()["search"]["used"] == 5


def test_guests_get_a_few_searches_a_day_then_are_asked_to_sign_up(api, engine):
    guest = device("guest-a")
    assert [search(api, guest).status_code for _ in range(3)] == [200] * 3
    blocked = search(api, guest)
    assert blocked.status_code == 402
    assert blocked.json()["detail"] == {
        "code": "sign_in_required", "feature": "search", "limit": 3,
        "message": "Create a free account to keep searching.",
    }
    assert api.get("/plus/status", headers=guest).json()["search"] == {"used": 3, "limit": 3}
    # A refused search isn't counted, and an account has its own five.
    with Session(engine) as db:
        counts = {c.subject: c.count for c in db.query(UsageCounter).filter_by(feature="guest_search")}
    assert counts == {"device:guest-a": 3, "ip:testclient": 3}
    headers, _, _ = account(engine, "guest-a")
    assert [search(api, headers).status_code for _ in range(5)] == [200] * 5


def test_guest_limits_also_hold_per_network(api):
    # New install ids on one network get three times a device's allowance in all.
    for phone in ("guest-a", "guest-b", "guest-c"):
        assert all(search(api, device(phone)).status_code == 200 for _ in range(3))
    assert search(api, device("guest-d")).status_code == 402
    # Without a device id, only the network's count applies.
    assert search(api).json()["detail"]["code"] == "sign_in_required"


def test_guest_searches_that_find_nothing_or_have_no_store_arent_counted(api):
    guest = device("guest-a")
    assert api.post("/search", json={"query": "milk", "store_id": 999}, headers=guest).status_code == 404
    # The intro's practice question has no store: a general answer, not one of the day's.
    assert all(api.post("/search", json={"query": "milk"}, headers=guest).status_code == 200 for _ in range(4))
    assert api.get("/plus/status", headers=guest).json()["search"]["used"] == 0


def test_guests_get_a_few_trip_routes_a_day(api, engine, monkeypatch):
    monkeypatch.setattr(get_settings(), "aisle_guest_routes", 2)
    trip = {"store_id": 1, "items": [{"id": "1", "text": "milk"}]}
    guest = device("guest-a")
    assert [api.post("/route", json=trip, headers=guest).status_code for _ in range(2)] == [200, 200]
    blocked = api.post("/route", json=trip, headers=guest)
    assert blocked.status_code == 402
    assert blocked.json()["detail"]["code"] == "sign_in_required"
    assert blocked.json()["detail"]["message"] == "Create a free account to keep planning trips."
    # A missing store isn't counted; accounts aren't held to it.
    assert api.post("/route", json={**trip, "store_id": 999}, headers=device("guest-b")).status_code == 404
    headers, _, _ = account(engine, "guest-a")
    assert all(api.post("/route", json=trip, headers=headers).status_code == 200 for _ in range(3))


def test_free_plan_gets_one_follow_up_per_search(api, apple, engine):
    headers, token, _ = account(engine)
    first = [{"role": "user", "content": "milk"}, {"role": "assistant", "content": "Dairy."},
             {"role": "user", "content": "and eggs?"}]
    assert api.post("/chat", json={"store_id": 1, "messages": first}, headers=headers).status_code == 200
    second = first + [{"role": "assistant", "content": "By the milk."}, {"role": "user", "content": "butter?"}]
    blocked = api.post("/chat", json={"store_id": 1, "messages": second}, headers=headers)
    assert blocked.status_code == 402
    assert blocked.json()["detail"]["message"] == "The free plan includes 1 follow-up per search. Aisle+ has unlimited."
    # A new search gets its own follow-up; Aisle+ has no per-search limit.
    assert api.post("/chat", json={"store_id": 1, "messages": first}, headers=headers).status_code == 200
    sync(api, headers, apple.sign(appAccountToken=token))
    assert api.post("/chat", json={"store_id": 1, "messages": second}, headers=headers).status_code == 200


def test_free_ai_answers_have_a_daily_limit_then_search_keeps_working(api, engine, monkeypatch):
    app.dependency_overrides[get_explainer] = lambda: RecordingAI("By the eggs.")
    app.dependency_overrides[get_location_model] = lambda: None
    monkeypatch.setattr(get_settings(), "aisle_free_ai_searches", 2)
    headers, _, _ = account(engine)
    answers = [search(api, headers) for _ in range(3)]
    assert [r.status_code for r in answers] == [200, 200, 200]
    assert [r.json()["explanation"] for r in answers] == ["By the eggs.", "By the eggs.", None]
    status = api.get("/plus/status", headers=headers).json()
    assert status["ai_search"] == {"used": 2, "limit": 2}


def test_signed_out_gets_fewer_ai_answers(api, monkeypatch):
    app.dependency_overrides[get_explainer] = lambda: RecordingAI("By the eggs.")
    app.dependency_overrides[get_location_model] = lambda: None
    monkeypatch.setattr(get_settings(), "aisle_signed_out_ai_searches", 1)
    assert [search(api).json()["explanation"] for _ in range(2)] == ["By the eggs.", None]


def test_search_without_an_ai_answer_isnt_counted(api, engine):
    app.dependency_overrides[get_explainer] = lambda: RecordingAI(None)
    app.dependency_overrides[get_location_model] = lambda: None
    headers, _, _ = account(engine)
    search(api, headers)
    assert api.get("/plus/status", headers=headers).json()["ai_search"]["used"] == 0


def test_aisle_plus_has_a_fair_use_ceiling(api, apple, engine, monkeypatch):
    monkeypatch.setattr(get_settings(), "aisle_plus_photo_searches", 2)
    headers, token, _ = account(engine)
    sync(api, headers, apple.sign(appAccountToken=token))
    statuses = [api.post("/identify", json={"image": PHOTO}, headers=headers).status_code for _ in range(3)]
    assert statuses == [200, 200, 429]
    # Fair use is counted apart from the free tier.
    assert api.get("/plus/status", headers=headers).json()["photo_search"]["used"] == 0


class PricedAI(RecordingAI):
    """Each answer costs $1 of the day's AI budget, as a provider call would."""

    def explain(self, facts):
        budget.charge("claude-opus-5-5", 250_000, 0)
        return super().explain(facts)

    def chat(self, system, messages):
        budget.charge("claude-opus-5-5", 250_000, 0)
        return super().chat(system, messages)


def test_everyones_ai_has_a_daily_budget(api, engine, monkeypatch):
    app.dependency_overrides[get_explainer] = lambda: PricedAI("By the eggs.")
    app.dependency_overrides[get_location_model] = lambda: None
    monkeypatch.setattr(get_settings(), "aisle_ai_budget_usd_per_day", 2.0)
    first, _, _ = account(engine, "phone-a")
    second, _, _ = account(engine, "phone-b")
    assert api.post("/identify", json={"image": PHOTO}, headers=first).status_code == 200
    assert search(api, first).json()["explanation"] == "By the eggs."
    # Budget spent: photo search pauses for everyone, and search falls back to Aisle's own answers.
    paused = api.post("/identify", json={"image": PHOTO}, headers=second)
    assert paused.status_code == 503 and "AI" in paused.json()["detail"]
    assert search(api, second).json()["explanation"] is None
    # The refused tries didn't use up the shopper's own allowance.
    assert api.get("/plus/status", headers=second).json()["photo_search"]["used"] == 0
    with Session(engine) as db:
        assert budget.spent_today(db) == 2.0


def test_every_ai_call_in_a_follow_up_is_charged(api, engine):
    app.dependency_overrides[get_explainer] = lambda: PricedAI()
    headers, _, _ = account(engine)
    convo = [{"role": "user", "content": "where's the milk?"}]
    assert api.post("/chat", json={"store_id": 1, "messages": convo}, headers=headers).status_code == 200
    # The reply (written on another thread) and the check for a new item to find.
    with Session(engine) as db:
        assert budget.spent_today(db) == 2.0
