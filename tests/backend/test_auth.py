"""Accounts: SMS and email codes, Apple and Google tokens, sessions, profile and deletion.

Twilio, Resend, Apple and Google are replaced with fakes; the token checks run for real
against RSA keys made here.
"""
import hashlib
import time
from datetime import datetime, timedelta, timezone

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from backend.app.auth import identity as identity_module
from backend.app.auth.codes import (
    CodeProblem, ResendEmailSender, TwilioPhoneVerifier, normalize_email, normalize_phone,
)
from backend.app.auth.identity import InvalidToken, JWKSIdentityVerifier, ProviderIdentity
from backend.app.database import get_db
from backend.app.main import app
from backend.app.models import CodeRequest
from backend.app.routers.auth import get_email_sender, get_identity_verifier, get_phone_verifier

NONCE = "raw-nonce-1234"

DEVICE = {"X-Aisle-Device": "device-1"}


class FakePhones:
    def __init__(self):
        self.sent = []
        self.valid_code = "123456"

    def send(self, phone):
        self.sent.append(phone)

    def check(self, phone, code):
        return code == self.valid_code


class FakeEmails:
    def __init__(self):
        self.codes = {}

    def send_code(self, email, code):
        self.codes[email] = code


class FakeIdentities:
    def __init__(self):
        self.apple_identity = ProviderIdentity("apple-sub-1", "sam@privaterelay.appleid.com", True)
        self.google_identity = ProviderIdentity("google-sub-1", "sam@example.com", True, "Sam")

    def apple(self, token, nonce):
        if token.startswith("bad"):
            raise InvalidToken("bad")
        return self.apple_identity

    def google(self, token, nonce):
        if token.startswith("bad"):
            raise InvalidToken("bad")
        return self.google_identity


@pytest.fixture
def fakes():
    return FakePhones(), FakeEmails(), FakeIdentities()


@pytest.fixture
def api(engine, fakes):
    phones, emails, identities = fakes

    def override_db():
        with Session(engine) as session:
            yield session

    app.dependency_overrides[get_db] = override_db
    app.dependency_overrides[get_phone_verifier] = lambda: phones
    app.dependency_overrides[get_email_sender] = lambda: emails
    app.dependency_overrides[get_identity_verifier] = lambda: identities
    with TestClient(app) as client:
        yield client
    app.dependency_overrides.clear()


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def phone_sign_in(api, phone="(215) 555-0123"):
    assert api.post("/auth/phone/start", json={"phone": phone}, headers=DEVICE).status_code == 200
    return api.post("/auth/phone/verify", json={"phone": phone, "code": "123456"}, headers=DEVICE)


# MARK: - SMS

def test_phone_sign_up_then_sign_in(api, fakes):
    phones = fakes[0]
    sent = api.post("/auth/phone/start", json={"phone": "(215) 555-0123"}, headers=DEVICE)
    assert sent.status_code == 200
    assert sent.json() == {"sent_to": "+1 •••• 0123", "retry_after": 30}
    assert phones.sent == ["+12155550123"]

    wrong = api.post("/auth/phone/verify", json={"phone": "2155550123", "code": "000000"})
    assert wrong.status_code == 400

    first = api.post("/auth/phone/verify", json={"phone": "215-555-0123", "code": "123456"}, headers=DEVICE)
    assert first.status_code == 200
    body = first.json()
    assert body["is_new"] is True
    assert body["user"]["phone"] == "+12155550123"
    assert body["user"]["providers"] == ["phone"]
    assert len(body["token"]) > 30

    again = api.post("/auth/phone/verify", json={"phone": "+1 215 555 0123", "code": "123456"})
    assert again.json()["is_new"] is False
    assert again.json()["user"]["id"] == body["user"]["id"]
    assert again.json()["token"] != body["token"]


def test_phone_codes_are_rate_limited(api, engine):
    assert api.post("/auth/phone/start", json={"phone": "2155550123"}, headers=DEVICE).status_code == 200
    too_soon = api.post("/auth/phone/start", json={"phone": "2155550123"}, headers=DEVICE)
    assert too_soon.status_code == 429
    assert "seconds" in too_soon.json()["detail"]

    # Five an hour per number, even spaced out past the 30-second cooldown.
    with Session(engine) as db:
        old = datetime.now(timezone.utc) - timedelta(minutes=10)
        db.add_all([CodeRequest(channel="sms", target="+12155550199", device_id="d", created_at=old)
                    for _ in range(5)])
        db.commit()
    assert api.post("/auth/phone/start", json={"phone": "2155550199"}).status_code == 429


def test_bad_phone_numbers_are_rejected(api):
    assert api.post("/auth/phone/start", json={"phone": "555-0123"}).status_code == 400


def test_normalize_phone():
    assert normalize_phone("(215) 555-0123") == "+12155550123"
    assert normalize_phone("1 215 555 0123") == "+12155550123"
    assert normalize_phone("+44 20 7946 0958") == "+442079460958"
    for bad in ["555-0123", "+0123456789", "12345", "+1234567890123456"]:
        with pytest.raises(CodeProblem):
            normalize_phone(bad)


def test_codes_unavailable_without_keys(api):
    app.dependency_overrides[get_phone_verifier] = lambda: None
    app.dependency_overrides[get_email_sender] = lambda: None
    assert api.post("/auth/phone/start", json={"phone": "2155550123"}).status_code == 503
    assert api.post("/auth/email/start", json={"email": "sam@example.com"}).status_code == 503


# MARK: - Email

def test_email_sign_up_and_codes_work_once(api, fakes):
    emails = fakes[1]
    sent = api.post("/auth/email/start", json={"email": "  Sam@Example.com "}, headers=DEVICE)
    assert sent.json()["sent_to"] == "sam@example.com"
    code = emails.codes["sam@example.com"]
    assert len(code) == 6 and code.isdigit()

    wrong = "000000" if code != "000000" else "111111"
    assert api.post("/auth/email/verify", json={"email": "sam@example.com", "code": wrong}).status_code == 400
    ok = api.post("/auth/email/verify", json={"email": "sam@example.com", "code": code})
    assert ok.status_code == 200
    assert ok.json()["user"]["email"] == "sam@example.com"
    assert ok.json()["is_new"] is True
    # A code works only once.
    assert api.post("/auth/email/verify", json={"email": "sam@example.com", "code": code}).status_code == 400


def test_email_code_locks_after_five_wrong_tries(api, fakes):
    api.post("/auth/email/start", json={"email": "sam@example.com"})
    code = fakes[1].codes["sam@example.com"]
    wrong = "000000" if code != "000000" else "111111"
    for _ in range(5):
        api.post("/auth/email/verify", json={"email": "sam@example.com", "code": wrong})
    locked = api.post("/auth/email/verify", json={"email": "sam@example.com", "code": code})
    assert locked.status_code == 429


def test_normalize_email():
    assert normalize_email(" Sam@Example.COM ") == "sam@example.com"
    for bad in ["sam", "sam@", "@example.com", "sam@example", "sam @example.com"]:
        with pytest.raises(CodeProblem):
            normalize_email(bad)


# MARK: - Apple and Google

def test_google_uses_its_name_and_links_to_the_same_email_account(api, fakes):
    api.post("/auth/email/start", json={"email": "sam@example.com"})
    by_email = api.post("/auth/email/verify", json={"email": "sam@example.com",
                                                     "code": fakes[1].codes["sam@example.com"]}).json()
    by_google = api.post("/auth/google", json={"id_token": "x" * 40, "nonce": NONCE}).json()
    assert by_google["is_new"] is False
    assert by_google["user"]["id"] == by_email["user"]["id"]
    assert by_google["user"]["providers"] == ["email", "google"]
    assert by_google["user"]["first_name"] == "Sam"


def test_apple_first_sign_in_keeps_the_name_the_app_sent(api):
    body = api.post("/auth/apple", json={"identity_token": "x" * 40, "nonce": NONCE, "first_name": "Sam"}).json()
    assert body["is_new"] is True
    assert body["user"]["first_name"] == "Sam"
    assert body["user"]["providers"] == ["apple"]
    assert api.post("/auth/apple", json={"identity_token": "x" * 40, "nonce": NONCE}).json()["is_new"] is False


def test_rejected_tokens_dont_sign_in(api):
    assert api.post("/auth/apple", json={"identity_token": "bad" + "x" * 40, "nonce": NONCE}).status_code == 401
    assert api.post("/auth/google", json={"id_token": "bad" + "x" * 40, "nonce": NONCE}).status_code == 401


# MARK: - Sessions, profile, deletion

def test_profile_sign_out_and_delete(api):
    token = phone_sign_in(api).json()["token"]
    assert api.get("/me").status_code == 401
    assert api.get("/me", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert api.get("/me", headers=bearer(token)).json()["first_name"] == ""

    updated = api.patch("/me", json={"first_name": "  Sam ", "wants_tips": True}, headers=bearer(token))
    assert updated.json()["first_name"] == "Sam" and updated.json()["wants_tips"] is True
    assert api.patch("/me", json={"first_name": "  "}, headers=bearer(token)).status_code == 422

    assert api.post("/auth/signout", headers=bearer(token)).status_code == 204
    assert api.get("/me", headers=bearer(token)).status_code == 401

    # Signing in again (the code was sent moments ago) finds the same account and name.
    second = api.post("/auth/phone/verify", json={"phone": "2155550123", "code": "123456"}).json()
    assert second["is_new"] is False and second["user"]["first_name"] == "Sam"
    assert api.delete("/me", headers=bearer(second["token"])).status_code == 204
    assert api.get("/me", headers=bearer(second["token"])).status_code == 401


def test_deleted_number_can_sign_up_again(api, engine):
    first = phone_sign_in(api).json()
    api.delete("/me", headers=bearer(first["token"]))
    with Session(engine) as db:
        db.query(CodeRequest).delete()
        db.commit()
    again = phone_sign_in(api).json()
    # A fresh account with nothing carried over (SQLite may reuse the row id).
    assert again["is_new"] is True
    assert again["user"]["first_name"] == "" and again["user"]["providers"] == ["phone"]


# MARK: - Adding a phone number

def google_sign_in(api):
    return api.post("/auth/google", json={"id_token": "x" * 40, "nonce": NONCE}).json()


def test_a_phone_added_to_a_google_account_signs_in_to_it(api, fakes):
    google = google_sign_in(api)
    assert api.post("/me/phone/start", json={"phone": "2155550123"}).status_code == 401
    sent = api.post("/me/phone/start", json={"phone": "(215) 555-0123"}, headers=bearer(google["token"]))
    assert sent.status_code == 200 and sent.json()["sent_to"] == "+1 •••• 0123"
    wrong = api.post("/me/phone/verify", json={"phone": "2155550123", "code": "000000"},
                     headers=bearer(google["token"]))
    assert wrong.status_code == 400

    added = api.post("/me/phone/verify", json={"phone": "2155550123", "code": "123456"},
                     headers=bearer(google["token"])).json()
    assert added["phone"] == "+12155550123"
    assert added["providers"] == ["google", "phone"]

    # Signing in by text now lands in the Google account, not a new one.
    by_phone = api.post("/auth/phone/verify", json={"phone": "2155550123", "code": "123456"}).json()
    assert by_phone["is_new"] is False
    assert by_phone["user"]["id"] == google["user"]["id"]


def test_adding_a_new_number_replaces_the_old_one(api, engine):
    google = google_sign_in(api)
    for phone in ("2155550123", "2155550188"):
        api.post("/me/phone/verify", json={"phone": phone, "code": "123456"}, headers=bearer(google["token"]))
    me = api.get("/me", headers=bearer(google["token"])).json()
    assert me["phone"] == "+12155550188" and me["providers"] == ["google", "phone"]
    # The old number no longer opens this account.
    old = api.post("/auth/phone/verify", json={"phone": "2155550123", "code": "123456"}).json()
    assert old["is_new"] is True


def test_a_number_with_its_own_account_cant_be_added(api):
    phone_sign_in(api)
    google = google_sign_in(api)
    taken = api.post("/me/phone/verify", json={"phone": "2155550123", "code": "123456"},
                     headers=bearer(google["token"]))
    assert taken.status_code == 409
    assert "own Aisle account" in taken.json()["detail"]


def test_adding_the_number_already_on_the_account(api):
    token = phone_sign_in(api).json()["token"]
    same = api.post("/me/phone/start", json={"phone": "2155550123"}, headers=bearer(token))
    assert same.status_code == 400
    # Verifying it anyway changes nothing.
    again = api.post("/me/phone/verify", json={"phone": "2155550123", "code": "123456"}, headers=bearer(token))
    assert again.json()["providers"] == ["phone"]


# MARK: - Real token checks

class FakeKeys:
    def __init__(self, public_key):
        self.public_key = public_key

    def get_signing_key_from_jwt(self, token):
        return type("Key", (), {"key": self.public_key})()


@pytest.fixture
def signing_key(monkeypatch):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    monkeypatch.setattr(identity_module, "_keys", lambda url: FakeKeys(key.public_key()))
    return key


def token(key, **claims):
    now = int(time.time())
    payload = {"iat": now, "exp": now + 600, "sub": "user-1", **claims}
    return jwt.encode(payload, key, algorithm="RS256")


def test_apple_token_checks(signing_key):
    verifier = JWKSIdentityVerifier("app.shopaisle.aisle", "client.apps.googleusercontent.com")
    hashed = hashlib.sha256(b"raw-nonce").hexdigest()
    good = token(signing_key, iss="https://appleid.apple.com", aud="app.shopaisle.aisle", nonce=hashed,
                 email="Sam@Example.com", email_verified="true")
    who = verifier.apple(good, "raw-nonce")
    assert (who.subject, who.email, who.email_verified) == ("user-1", "sam@example.com", True)

    with pytest.raises(InvalidToken):
        verifier.apple(good, "other-nonce")
    for bad in [
        token(signing_key, iss="https://appleid.apple.com", aud="com.someone.else"),
        token(signing_key, iss="https://evil.example", aud="app.shopaisle.aisle"),
        token(signing_key, iss="https://appleid.apple.com", aud="app.shopaisle.aisle", exp=int(time.time()) - 10),
        token(rsa.generate_private_key(public_exponent=65537, key_size=2048),
              iss="https://appleid.apple.com", aud="app.shopaisle.aisle"),
    ]:
        with pytest.raises(InvalidToken):
            verifier.apple(bad, None)


def test_google_token_checks(signing_key):
    verifier = JWKSIdentityVerifier("app.shopaisle.aisle", "client.apps.googleusercontent.com")
    good = token(signing_key, iss="https://accounts.google.com", aud="client.apps.googleusercontent.com",
                 nonce="raw-nonce", email="sam@example.com", email_verified=True, given_name="Sam")
    who = verifier.google(good, "raw-nonce")
    assert (who.email, who.given_name, who.email_verified) == ("sam@example.com", "Sam", True)
    with pytest.raises(InvalidToken):
        verifier.google(good, "other")
    with pytest.raises(InvalidToken):
        JWKSIdentityVerifier("app.shopaisle.aisle", None).google(good, None)


# MARK: - Twilio and Resend requests

def test_twilio_requests_and_errors():
    seen = []

    def handler(request):
        seen.append(request)
        if request.url.path.endswith("/Verifications"):
            to = dict(httpx.QueryParams(request.content.decode()))["To"]
            if to == "+15550000000":
                return httpx.Response(400, json={"code": 60200})
            return httpx.Response(201, json={"status": "pending"})
        code = dict(httpx.QueryParams(request.content.decode()))["Code"]
        if code == "999999":
            return httpx.Response(404, json={"code": 20404})
        return httpx.Response(200, json={"status": "approved" if code == "123456" else "pending"})

    client = httpx.Client(transport=httpx.MockTransport(handler))
    twilio = TwilioPhoneVerifier("ACx", "secret", "VAx", client=client)
    twilio.send("+12155550123")
    assert seen[0].url.path == "/v2/Services/VAx/Verifications"
    assert seen[0].headers["Authorization"].startswith("Basic ")
    assert twilio.check("+12155550123", "123456") is True
    assert twilio.check("+12155550123", "000000") is False
    with pytest.raises(CodeProblem):
        twilio.send("+15550000000")
    with pytest.raises(CodeProblem):
        twilio.check("+12155550123", "999999")


def test_resend_request():
    seen = []

    def handler(request):
        seen.append(request)
        return httpx.Response(200, json={"id": "email-1"})

    sender = ResendEmailSender("re_test", "Aisle <codes@shopaisle.app>",
                               client=httpx.Client(transport=httpx.MockTransport(handler)))
    sender.send_code("sam@example.com", "123456")
    request = seen[0]
    assert request.url == "https://api.resend.com/emails"
    assert request.headers["Authorization"] == "Bearer re_test"
    body = request.read().decode()
    assert '"to":["sam@example.com"]' in body.replace(" ", "")
    assert "123456 is your Aisle code" in body
    # The wordmark rides along as an inline image the HTML points at.
    assert '"content_id":"aisle-wordmark"' in body.replace(" ", "")
    assert "cid:aisle-wordmark" in body
