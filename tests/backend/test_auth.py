"""Accounts: SMS and email codes, Apple and Google tokens, sessions, profile and deletion,
revoking Sign in with Apple, and Apple's notifications.

Twilio, Resend, Apple and Google are replaced with fakes; the token checks run for real
against RSA keys made here.
"""
import hashlib
import json
import logging
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
    CodeProblem, ResendEmailSender, TwilioPhoneVerifier, canonical_email, check_sms_country, normalize_email,
    normalize_phone, target_key,
)
from backend.app.auth.identity import InvalidToken, JWKSIdentityVerifier, ProviderIdentity
from backend.app.database import get_db
from backend.app.main import app
from backend.app.config import get_settings
from backend.app.models import AppleRevocation, AuthSession, CodeRequest
from backend.app.routers.auth import get_apple_tokens, get_email_sender, get_identity_verifier, get_phone_verifier

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
    # No Sign in with Apple key unless a test installs fake Apple tokens.
    app.dependency_overrides[get_apple_tokens] = lambda: None
    with TestClient(app) as client:
        client.app_engine = engine
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
        db.add_all([CodeRequest(channel="sms", target=target_key("sms", "+12155550199"), device_id="d",
                                created_at=old) for _ in range(5)])
        db.commit()
    assert api.post("/auth/phone/start", json={"phone": "2155550199"}).status_code == 429


def test_bad_phone_numbers_are_rejected(api):
    assert api.post("/auth/phone/start", json={"phone": "555-0123"}).status_code == 400


def test_code_records_keep_only_a_hash(api, engine):
    api.post("/auth/phone/start", json={"phone": "2155550123"}, headers=DEVICE)
    api.post("/auth/email/start", json={"email": "sam@example.com"}, headers=DEVICE)
    with Session(engine) as db:
        targets = {r.target for r in db.query(CodeRequest)}
    assert targets == {target_key("sms", "+12155550123"), target_key("email", "sam@example.com")}
    assert not any("2155550123" in t or "example" in t for t in targets)


def test_texts_only_go_to_the_us_and_canada():
    for ok in ["+12155550123", "+14165550123", "+17875550123"]:  # Philadelphia, Toronto, Puerto Rico
        check_sms_country(ok, ("1",))
    # +1 also covers the Caribbean and Bermuda (Jamaica, the Dominican Republic) and
    # premium-rate numbers, which SMS-pumping fraud loves.
    for bad in ["+18765550123", "+18095550123", "+14415550123", "+19005550123", "+447700900123"]:
        with pytest.raises(CodeProblem):
            check_sms_country(bad, ("1",))
    check_sms_country("+18765550123", ("1", "1876"))  # Unless listed outright.
    check_sms_country("+447700900123", ("1", "44"))


def test_one_mailbox_shares_its_code_limits(api):
    assert canonical_email("sam.smith+aisle@gmail.com") == "samsmith@gmail.com"
    assert canonical_email("sam+x@googlemail.com") == "sam@gmail.com"
    assert canonical_email("sam.smith+x@example.com") == "sam.smith@example.com"
    assert api.post("/auth/email/start", json={"email": "sam.smith@gmail.com"}).status_code == 200
    # Another spelling of the same Gmail inbox waits out the same cooldown.
    assert api.post("/auth/email/start", json={"email": "samsmith+2@gmail.com"}).status_code == 429


def test_past_the_overall_cap_only_existing_accounts_get_codes(api, monkeypatch):
    token = phone_sign_in(api).json()["token"]
    monkeypatch.setattr(get_settings(), "aisle_codes_per_hour", 1)
    stranger = api.post("/auth/phone/start", json={"phone": "2155550177"})
    assert stranger.status_code == 429 and "a lot of codes" in stranger.json()["detail"]
    # Signed out and back in later, the number already on an account still gets its code.
    api.post("/auth/signout", headers=bearer(token))
    with Session(api.app_engine) as db:
        db.query(CodeRequest).update({CodeRequest.created_at: datetime.now(timezone.utc) - timedelta(minutes=5)})
        db.commit()
    assert api.post("/auth/phone/start", json={"phone": "2155550123"}).status_code == 200


def test_deleting_the_account_doesnt_reset_code_limits(api):
    token = phone_sign_in(api).json()["token"]
    assert api.delete("/me", headers=bearer(token)).status_code == 204
    # The code sent moments ago still counts: no new one yet.
    assert api.post("/auth/phone/start", json={"phone": "2155550123"}, headers=DEVICE).status_code == 429


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
    again = api.post("/auth/apple", json={"identity_token": "y" * 40, "nonce": NONCE + "-2"}).json()
    assert again["is_new"] is False


def test_an_id_token_signs_in_once(api):
    first = api.post("/auth/apple", json={"identity_token": "x" * 40, "nonce": NONCE})
    assert first.status_code == 200
    # Replaying the same token (its nonce) is refused, even after deleting the account.
    api.delete("/me", headers=bearer(first.json()["token"]))
    replayed = api.post("/auth/apple", json={"identity_token": "x" * 40, "nonce": NONCE})
    assert replayed.status_code == 401
    assert api.post("/auth/google", json={"id_token": "x" * 40, "nonce": NONCE}).status_code == 200
    assert api.post("/auth/google", json={"id_token": "x" * 40, "nonce": NONCE}).status_code == 401


def test_a_network_can_only_make_so_many_accounts_a_day(api, monkeypatch):
    monkeypatch.setattr(get_settings(), "aisle_new_accounts_per_ip_per_day", 2)
    for n in range(2):
        assert phone_sign_in(api, f"215555010{n}").json()["is_new"] is True
    blocked = phone_sign_in(api, "2155550109")
    assert blocked.status_code == 429 and "new accounts" in blocked.json()["detail"]
    # Signing in to an account that already exists still works.
    with Session(api.app_engine) as db:
        db.query(CodeRequest).delete()
        db.commit()
    assert phone_sign_in(api, "2155550100").json()["is_new"] is False


def test_sign_in_attempts_are_limited_per_network(api, monkeypatch):
    monkeypatch.setattr(get_settings(), "aisle_sign_ins_per_hour", 3)
    statuses = [api.post("/auth/email/verify", json={"email": "sam@example.com", "code": "123456"}).status_code
                for _ in range(4)]
    assert statuses == [400, 400, 400, 429]


def test_sessions_end_after_90_days_unused(api, engine):
    token = phone_sign_in(api).json()["token"]
    assert api.get("/me", headers=bearer(token)).status_code == 200
    with Session(engine) as db:
        db.query(AuthSession).update({AuthSession.last_used_at: datetime.now(timezone.utc) - timedelta(days=91)})
        db.commit()
    assert api.get("/me", headers=bearer(token)).status_code == 401


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


# MARK: - Revoking Sign in with Apple

class FakeAppleTokens:
    def __init__(self, revokes=True):
        self.traded = []
        self.revoked = []
        self.revokes = revokes

    def refresh_token(self, code):
        self.traded.append(code)
        return None if code.startswith("bad") else f"refresh-for-{code}"

    def revoke(self, token):
        self.revoked.append(token)
        return self.revokes


@pytest.fixture
def apple_tokens(api):
    fake = FakeAppleTokens()
    app.dependency_overrides[get_apple_tokens] = lambda: fake
    return fake


def apple_sign_in(api, nonce=NONCE, code=None):
    body = {"identity_token": "x" * 40, "nonce": nonce}
    if code:
        body["authorization_code"] = code
    return api.post("/auth/apple", json=body).json()


def delete_account(api, token, code=None):
    body = {"authorization_code": code} if code else None
    return api.request("DELETE", "/me", json=body, headers=bearer(token))


def pending_revocations(engine):
    with Session(engine) as db:
        return [(r.refresh_token, r.authorization_code) for r in db.query(AppleRevocation).order_by(AppleRevocation.id)]


def test_deleting_an_apple_account_revokes_it_with_a_fresh_code(api, engine, apple_tokens):
    token = apple_sign_in(api, code="sign-in-code")["token"]
    assert delete_account(api, token, code="fresh-code").status_code == 204
    assert api.get("/me", headers=bearer(token)).status_code == 401
    # The fresh code's token is revoked; one revocation ends Aisle's Apple sign-in.
    assert apple_tokens.traded == ["sign-in-code", "fresh-code"]
    assert apple_tokens.revoked == ["refresh-for-fresh-code"]
    assert pending_revocations(engine) == []


def test_older_apps_delete_without_a_code(api, engine, apple_tokens):
    token = apple_sign_in(api, code="sign-in-code")["token"]
    assert api.delete("/me", headers=bearer(token)).status_code == 204
    assert apple_tokens.revoked == ["refresh-for-sign-in-code"]
    # A code Apple refuses falls back to the token kept at sign-in too.
    token = apple_sign_in(api, nonce=NONCE + "-2", code="sign-in-code-2")["token"]
    assert delete_account(api, token, code="bad-code").status_code == 204
    assert apple_tokens.revoked[-1] == "refresh-for-sign-in-code-2"
    # Accounts without Apple don't touch Apple at all.
    assert delete_account(api, phone_sign_in(api).json()["token"]).status_code == 204
    assert len(apple_tokens.revoked) == 2 and pending_revocations(engine) == []


def test_without_the_apple_key_deletion_works_and_is_kept_to_revoke(api, engine, monkeypatch, caplog):
    monkeypatch.setenv("DYNO", "web.1")  # Production, where this must reach Sentry.
    token = apple_sign_in(api)["token"]
    with caplog.at_level(logging.WARNING):
        assert delete_account(api, token, code="fresh-code").status_code == 204
    assert api.get("/me", headers=bearer(token)).status_code == 401
    assert any(r.levelno == logging.ERROR and "Sign in with Apple key" in r.message for r in caplog.records)
    assert pending_revocations(engine) == [(None, "fresh-code")]


def test_when_apple_cant_revoke_it_waits_for_cleanup(api, engine, apple_tokens):
    apple_tokens.revokes = False
    token = apple_sign_in(api, code="sign-in-code")["token"]
    assert delete_account(api, token, code="fresh-code").status_code == 204
    assert api.get("/me", headers=bearer(token)).status_code == 401
    assert apple_tokens.revoked == ["refresh-for-fresh-code", "refresh-for-sign-in-code"]
    # Tokens only, never a client secret.
    assert pending_revocations(engine) == [("refresh-for-fresh-code", None), ("refresh-for-sign-in-code", None)]


def test_cleanup_retries_revocations_with_backoff(engine):
    from backend.app.auth.apple_revocation import retry_pending

    now = datetime.now(timezone.utc)
    failing, working = FakeAppleTokens(revokes=False), FakeAppleTokens()
    with Session(engine) as db:
        db.add(AppleRevocation(refresh_token="token-1", created_at=now, next_attempt_at=now))
        db.commit()
        # Without the key nothing is tried, and the row waits.
        assert retry_pending(db, None, now) == {"revoked": 0, "waiting": 1, "gave_up": 0}
        assert retry_pending(db, failing, now) == {"revoked": 0, "waiting": 1, "gave_up": 0}
        pending = db.query(AppleRevocation).one()
        assert pending.attempts == 1
        # Not due again for an hour, then twice as long after each failure.
        assert retry_pending(db, failing, now + timedelta(minutes=30))["waiting"] == 0
        assert retry_pending(db, failing, now + timedelta(hours=1)) == {"revoked": 0, "waiting": 1, "gave_up": 0}
        db.refresh(pending)
        assert pending.attempts == 2
        assert retry_pending(db, working, now + timedelta(hours=2))["waiting"] == 0
        assert retry_pending(db, working, now + timedelta(hours=4)) == {"revoked": 1, "waiting": 0, "gave_up": 0}
        assert working.revoked == ["token-1"] and db.query(AppleRevocation).count() == 0

        # A code (kept when the key wasn't set) is traded while it still works.
        db.add(AppleRevocation(authorization_code="fresh-code", created_at=now, next_attempt_at=now))
        db.commit()
        assert retry_pending(db, working, now + timedelta(minutes=2))["revoked"] == 1
        assert working.revoked[-1] == "refresh-for-fresh-code"


def test_cleanup_gives_up_on_revocations(engine, caplog):
    from backend.app.auth.apple_revocation import MAX_ATTEMPTS, retry_pending

    now = datetime.now(timezone.utc)
    with Session(engine) as db:
        db.add_all([
            AppleRevocation(refresh_token="tried-a-lot", attempts=MAX_ATTEMPTS - 1, created_at=now, next_attempt_at=now),
            AppleRevocation(refresh_token="never-had-a-key", created_at=now - timedelta(days=15), next_attempt_at=now),
            AppleRevocation(authorization_code="expired-code", created_at=now - timedelta(minutes=10),
                            next_attempt_at=now),
        ])
        db.commit()
        with caplog.at_level(logging.ERROR):
            assert retry_pending(db, None, now) == {"revoked": 0, "waiting": 1, "gave_up": 2}
            assert retry_pending(db, FakeAppleTokens(revokes=False), now) == {"revoked": 0, "waiting": 0, "gave_up": 1}
        assert db.query(AppleRevocation).count() == 0
        assert sum(r.levelno == logging.ERROR for r in caplog.records) == 3


def test_apple_token_requests():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    from backend.app.auth.apple_tokens import AppleTokenService

    seen = []

    def handler(request):
        seen.append(request)
        form = dict(httpx.QueryParams(request.content.decode()))
        if form.get("token") == "unknown":
            return httpx.Response(400, json={"error": "invalid_request"})
        return httpx.Response(200, json={"refresh_token": "r-1"} if request.url.path == "/auth/token" else {})

    key = ec.generate_private_key(ec.SECP256R1()).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()
    service = AppleTokenService("app.shopaisle.aisle", "983N58VUTZ", "KEY123", key,
                                client=httpx.Client(transport=httpx.MockTransport(handler)))
    assert service.refresh_token("code-1") == "r-1"
    assert service.revoke("r-1") is True
    assert service.revoke("unknown") is False
    form = dict(httpx.QueryParams(seen[1].content.decode()))
    assert seen[1].url == "https://appleid.apple.com/auth/revoke"
    assert (form["client_id"], form["token"], form["token_type_hint"]) == ("app.shopaisle.aisle", "r-1", "refresh_token")
    secret = jwt.decode(form["client_secret"], options={"verify_signature": False})
    assert (secret["iss"], secret["sub"], secret["aud"]) == ("983N58VUTZ", "app.shopaisle.aisle",
                                                             "https://appleid.apple.com")


# MARK: - Sign in with Apple notifications

def apple_event(key, kind, sub="apple-sub-1", jti=None, **claims):
    now = int(time.time())
    events = json.dumps({"type": kind, "sub": sub, "event_time": now * 1000})
    payload = {"iss": "https://appleid.apple.com", "aud": "app.shopaisle.aisle", "iat": now,
               "jti": jti or f"{kind}-{sub}", "events": events, **claims}
    return {"payload": jwt.encode(payload, key, algorithm="RS256")}


@pytest.fixture
def notices(api, signing_key):
    """Accounts are made with the fake Apple identity; notifications are checked for real."""
    real = JWKSIdentityVerifier("app.shopaisle.aisle", None)

    def post(body):
        fake = app.dependency_overrides[get_identity_verifier]
        app.dependency_overrides[get_identity_verifier] = lambda: real
        try:
            return api.post("/auth/apple/notifications", json=body)
        finally:
            app.dependency_overrides[get_identity_verifier] = fake

    return post


def test_apple_notifications_must_be_signed_by_apple(api, notices, signing_key):
    token = apple_sign_in(api)["token"]
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    for bad in [
        apple_event(other, "account-delete"),
        apple_event(signing_key, "account-delete", aud="com.someone.else"),
        apple_event(signing_key, "account-delete", iss="https://evil.example"),
        apple_event(signing_key, "account-delete", events="not json"),
        apple_event(signing_key, "account-delete", exp=int(time.time()) - 10),
    ]:
        assert notices(bad).status_code == 400
    assert api.get("/me", headers=bearer(token)).status_code == 200


def test_consent_revoked_unlinks_apple_and_signs_out(api, notices, signing_key):
    token = apple_sign_in(api)["token"]
    api.post("/me/phone/verify", json={"phone": "2155550123", "code": "123456"}, headers=bearer(token))
    assert notices(apple_event(signing_key, "consent-revoked")).json() == {"ok": True}
    assert api.get("/me", headers=bearer(token)).status_code == 401
    by_phone = phone_sign_in(api).json()
    assert by_phone["is_new"] is False and by_phone["user"]["providers"] == ["phone"]
    # Replays, other events and unknown Apple IDs change nothing.
    assert notices(apple_event(signing_key, "consent-revoked")).status_code == 200
    assert notices(apple_event(signing_key, "email-disabled")).status_code == 200
    assert notices(apple_event(signing_key, "account-delete", sub="someone-else")).status_code == 200
    assert api.get("/me", headers=bearer(by_phone["token"])).status_code == 200


def test_a_deleted_apple_id_deletes_an_apple_only_account(api, notices, signing_key):
    token = apple_sign_in(api)["token"]
    assert notices(apple_event(signing_key, "account-delete")).status_code == 200
    assert api.get("/me", headers=bearer(token)).status_code == 401
    assert apple_sign_in(api, nonce=NONCE + "-2")["is_new"] is True


def test_a_deleted_apple_id_keeps_an_account_with_another_way_in(api, notices, signing_key):
    token = apple_sign_in(api)["token"]
    api.post("/me/phone/verify", json={"phone": "2155550123", "code": "123456"}, headers=bearer(token))
    assert notices(apple_event(signing_key, "account-delete")).status_code == 200
    assert api.get("/me", headers=bearer(token)).status_code == 401
    assert phone_sign_in(api).json()["user"]["providers"] == ["phone"]
