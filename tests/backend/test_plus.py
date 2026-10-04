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

from backend.app.ai.providers import get_explainer
from backend.app.config import get_settings
from backend.app.database import get_db
from backend.app.main import app
from backend.app.models import Retailer, Store, UsageCounter
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
            "signedDate": now_ms,
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
        yield client
    app.dependency_overrides.clear()


def device(name):
    return {"X-Aisle-Device": name}


def identify(api, who):
    return api.post("/identify", json={"image": PHOTO}, headers=device(who))


def test_free_photo_searches_stop_at_the_daily_limit(api):
    for _ in range(5):
        assert identify(api, "phone-a").json() == {"item": "milk"}
    blocked = identify(api, "phone-a")
    assert blocked.status_code == 402
    assert blocked.json()["detail"]["code"] == "plus_required"
    assert blocked.json()["detail"]["feature"] == "photo_search"
    assert "5 free photo searches" in blocked.json()["detail"]["message"]
    # Another device has its own allowance; list scans share the same one.
    assert identify(api, "phone-b").status_code == 200
    assert api.post("/lists/scan", json={"image": PHOTO}, headers=device("phone-a")).status_code == 402

    status = api.get("/plus/status", headers=device("phone-a")).json()
    assert status["is_plus"] is False
    assert status["photo_search"] == {"used": 5, "limit": 5}


def test_limits_reset_each_day(api, engine):
    for _ in range(5):
        identify(api, "phone-a")
    with Session(engine) as db:
        for counter in db.query(UsageCounter):
            counter.day = "2000-01-01"
        db.commit()
    assert identify(api, "phone-a").status_code == 200


def test_follow_ups_have_their_own_limit_and_photos_count_as_photo_searches(api):
    convo = [{"role": "user", "content": "milk"}, {"role": "assistant", "content": "Dairy."},
             {"role": "user", "content": "and eggs?"}]
    for _ in range(10):
        assert api.post("/chat", json={"store_id": 1, "messages": convo}, headers=device("p")).status_code == 200
    assert api.post("/chat", json={"store_id": 1, "messages": convo}, headers=device("p")).status_code == 402
    with_photo = convo[:2] + [{"role": "user", "content": "this?", "image": PHOTO}]
    assert api.post("/chat", json={"store_id": 1, "messages": with_photo}, headers=device("p")).status_code == 200
    status = api.get("/plus/status", headers=device("p")).json()
    assert status["follow_up"]["used"] == 10 and status["photo_search"]["used"] == 1


def test_a_verified_subscription_lifts_the_limits(api, apple):
    for _ in range(5):
        identify(api, "phone-a")
    synced = api.post("/plus/sync", json={"transactions": [apple.sign()]}, headers=device("phone-a"))
    assert synced.status_code == 200
    assert synced.json()["is_plus"] is True
    for _ in range(3):
        assert identify(api, "phone-a").status_code == 200
    # Unlimited use isn't counted.
    assert api.get("/plus/status", headers=device("phone-a")).json()["photo_search"]["used"] == 5


def test_expired_or_refunded_subscriptions_dont_count(api, apple):
    past = int(time.time() * 1000) - 1000
    assert api.post("/plus/sync", json={"transactions": [apple.sign(expiresDate=past)]},
                    headers=device("a")).json()["is_plus"] is False
    refunded = apple.sign(originalTransactionId="77", revocationDate=past)
    assert api.post("/plus/sync", json={"transactions": [refunded]}, headers=device("b")).json()["is_plus"] is False


def test_unverifiable_purchases_are_refused(api):
    refused = api.post("/plus/sync", json={"transactions": ["a.b.c"]}, headers=device("a"))
    assert refused.status_code == 400
    assert api.post("/plus/sync", json={"transactions": []}, headers=device("a")).json()["is_plus"] is False


def test_xcode_purchases_follow_the_setting(api, apple, monkeypatch):
    monkeypatch.setattr(get_settings(), "aisle_plus_allow_xcode", False)
    xcode = apple.sign(environment="Xcode", originalTransactionId="55")
    assert api.post("/plus/sync", json={"transactions": [xcode]}, headers=device("a")).status_code == 400
    monkeypatch.setattr(get_settings(), "aisle_plus_allow_xcode", True)
    assert api.post("/plus/sync", json={"transactions": [xcode]}, headers=device("a")).json()["is_plus"] is True
