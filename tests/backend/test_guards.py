"""What keeps the API up for everyone: request sizes, photos only for accounts, store
lookup limits, and the security headers on every response."""
import asyncio
import base64

import pytest
from fastapi.testclient import TestClient

from backend.app import schemas
from backend.app.config import get_settings
from backend.app.main import app
from backend.app.middleware import MAX_BODY_BYTES, MAX_PHOTO_BODY_BYTES, RequestGuard, SecurityHeaders

from conftest import signed_in_headers

PHOTO = base64.b64encode(b"\xff\xd8\xff\xe0 a photo").decode()


@pytest.fixture
def no_photo_decoding(monkeypatch):
    def decode(value):
        raise AssertionError("A photo was decoded")
    monkeypatch.setattr(schemas, "check_photo", decode)


# MARK: - Request sizes

def test_bodies_past_the_limit_get_413(seeded_client):
    big = {"text": "milk " * (MAX_BODY_BYTES // 5)}
    assert seeded_client.post("/lists/parse", json=big).status_code == 413
    assert seeded_client.post("/lists/parse", json={"text": "milk"}).status_code == 200
    # Without a Content-Length, reading stops at the limit.
    def chunks():
        for _ in range(MAX_BODY_BYTES // 1024 + 2):
            yield b"x" * 1024
    streamed = seeded_client.post("/events", content=chunks(), headers={"content-type": "application/json"})
    assert streamed.status_code >= 400


def test_signed_in_photos_get_the_photo_sized_limit(signed_in_client):
    big = {"store_id": 1, "messages": [{"role": "user", "content": "x" * (MAX_BODY_BYTES + 1000)}]}
    # Past the usual limit but a photo route: read, then refused for its content.
    assert signed_in_client.post("/chat", json=big).status_code == 422
    too_big = {"image": "a" * (MAX_PHOTO_BODY_BYTES + 1)}
    assert signed_in_client.post("/identify", json=too_big).status_code == 413


@pytest.mark.parametrize("path, what", [
    ("/chat", "follow-ups"), ("/identify", "photo search"), ("/lists/scan", "list scanning"),
])
def test_signed_out_photos_are_refused_before_the_body_is_read(path, what):
    sent = []

    async def route(scope, receive, send):
        raise AssertionError("The route ran")

    async def receive():
        raise AssertionError("The body was read")

    async def send(message):
        sent.append(message)

    scope = {"type": "http", "method": "POST", "path": path, "headers": [(b"content-length", b"3000000")]}
    asyncio.run(RequestGuard(route)(scope, receive, send))
    assert sent[0]["status"] == 401
    assert sent[1]["body"] == f'{{"detail": "Sign in to use {what}."}}'.encode()


def test_photos_with_a_made_up_token_are_refused_before_decoding(seeded_client, no_photo_decoding):
    made_up = {"Authorization": "Bearer not-a-real-session"}
    for path, body in (("/identify", {"image": PHOTO}), ("/lists/scan", {"image": PHOTO}),
                       ("/chat", {"store_id": 1, "messages": [{"role": "user", "content": "", "image": PHOTO}]})):
        assert seeded_client.post(path, json=body).status_code == 401
        refused = seeded_client.post(path, json=body, headers=made_up)
        assert refused.status_code == 401 and refused.json()["detail"].startswith("Sign in to use")


def test_a_follow_up_carries_at_most_a_couple_of_photos(signed_in_client, no_photo_decoding):
    photo = {"role": "user", "content": "this?", "image": PHOTO}
    said = {"role": "assistant", "content": "Oat milk."}
    convo = [photo, said, photo, said, photo]
    refused = signed_in_client.post("/chat", json={"store_id": 1, "messages": convo})
    assert refused.status_code == 422
    assert "at most 2" in refused.text


# MARK: - Store lookups

def test_store_lookups_are_rate_limited(client, monkeypatch):
    monkeypatch.setattr(get_settings(), "aisle_store_lookups_per_hour", 3)
    one, other = {"X-Forwarded-For": "198.51.100.1"}, {"X-Forwarded-For": "198.51.100.2"}
    near = {"lat": 40, "lon": -75}
    assert client.get("/stores/nearby", params=near, headers=one).status_code == 200
    assert client.get("/stores/search", params={"q": "near"}, headers=one).status_code == 200
    assert client.get("/stores/nearby", params=near, headers=one).status_code == 200
    assert client.get("/stores/search", params={"q": "near"}, headers=one).status_code == 429
    assert client.get("/stores/nearby", params=near, headers=one).status_code == 429
    # Another network has its own allowance.
    assert client.get("/stores/nearby", params=near, headers=other).status_code == 200


def test_store_search_matches_only_its_first_few_words(client):
    assert [s["name"] for s in client.get("/stores/search", params={"q": "near market st 10 trader joe's"}).json()] \
        == ["Near Store"]
    # The seventh word on isn't matched, so it can't make the search slower (or narrower).
    many = "near market st 10 trader joe's " + " ".join(f"word{n}" for n in range(20))
    assert [s["name"] for s in client.get("/stores/search", params={"q": many}).json()] == ["Near Store"]


# MARK: - Security headers

def test_security_headers_on_json_and_html(client):
    for path in ("/health", "/stores/99999", "/privacy", "/terms", "/support"):
        response = client.get(path)
        assert response.headers["x-content-type-options"] == "nosniff"
        assert response.headers["referrer-policy"] == "no-referrer"
        assert response.headers["content-security-policy"] == "frame-ancestors 'none'"
        assert response.headers["x-frame-options"] == "DENY"
        assert "strict-transport-security" not in response.headers  # Only on Heroku.
    assert client.get("/health").json() == {"status": "ok"}
    page = client.get("/privacy")
    assert page.headers["content-type"].startswith("text/html") and "<style>" in page.text
    # The guard's own refusals get them too.
    refused = client.post("/identify", json={"image": PHOTO})
    assert refused.status_code == 401 and refused.headers["x-frame-options"] == "DENY"


def test_https_only_on_heroku():
    async def route(scope, receive, send):
        await send({"type": "http.response.start", "status": 200, "headers": [(b"content-type", b"text/plain")]})
        await send({"type": "http.response.body", "body": b"ok"})

    for hsts in (False, True):
        response = TestClient(SecurityHeaders(route, hsts=hsts)).get("/")
        assert response.text == "ok" and response.headers["content-type"] == "text/plain"
        assert response.headers.get("strict-transport-security") == (
            "max-age=31536000; includeSubDomains" if hsts else None)
