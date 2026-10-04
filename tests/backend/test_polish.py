from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from backend.app.ai.cache import CachedLocationModel
from backend.app.ai.catalog import LAYOUTS
from backend.app.ai.intent import parse_intent
from backend.app.ai.reasoning import LocationGuess
from backend.app.main import app
from backend.app.models import AnalyticsEvent

from conftest import store_id_for


def test_analytics_batch_is_stored(seeded_client, seeded_engine):
    future = (datetime.now(timezone.utc) + timedelta(days=2)).isoformat()
    response = seeded_client.post("/events", headers={"X-Aisle-Device": "dev-1"}, json={"events": [
        {"name": "app_opened"},
        {"name": "search_submitted", "properties": {"source": "fallback", "confidence": "medium", "has_store": True}},
        {"name": "shopping_finished", "occurred_at": future, "properties": {"found": 4, "skipped": 1}},
    ]})
    assert response.status_code == 202
    assert response.json() == {"accepted": 3}
    with Session(seeded_engine) as session:
        events = session.scalars(select(AnalyticsEvent).order_by(AnalyticsEvent.id)).all()
        assert [e.name for e in events] == ["app_opened", "search_submitted", "shopping_finished"]
        assert events[1].properties == {"source": "fallback", "confidence": "medium", "has_store": True}
        assert all(e.device_id == "dev-1" for e in events)
        # Future client timestamps are clamped to the server clock.
        assert events[2].occurred_at.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc)


@pytest.mark.parametrize("events", [
    [],
    [{"name": "made_up_event"}],
    [{"name": "app_opened", "properties": {"q": "x" * 81}}],
    [{"name": "app_opened", "properties": {"nested": {"a": 1}}}],
    [{"name": "app_opened", "properties": {f"k{n}": n for n in range(13)}}],
    [{"name": "app_opened"}] * 51,
])
def test_analytics_validation(seeded_client, events):
    assert seeded_client.post("/events", json={"events": events}).status_code == 422


def test_zones_are_cacheable(seeded_client):
    store_id = store_id_for(seeded_client, "Target")
    response = seeded_client.get(f"/stores/{store_id}/zones")
    assert response.headers["cache-control"] == "public, max-age=300"


def test_unexpected_errors_return_json(seeded_client, monkeypatch):
    import backend.app.routers.search as search_router

    def boom(*args, **kwargs):
        raise RuntimeError("database fell over")

    monkeypatch.setattr(search_router, "search", boom)
    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.post("/search", json={"query": "milk"})
    assert response.status_code == 500
    assert response.json() == {"detail": "Something went wrong. Please try again."}
    assert "database fell over" not in response.text


class CountingModel:
    name = "counting"

    def __init__(self, results):
        self.results = list(results)
        self.calls = 0

    def locate(self, intent, retailer_name, layout):
        self.calls += 1
        return self.results.pop(0)


def test_model_cache_reuses_answers_until_ttl():
    now = [0.0]
    guess = LocationGuess(category=None, department="Produce", source="model")
    inner = CountingModel([guess, guess])
    cached = CachedLocationModel(inner, ttl_seconds=60, clock=lambda: now[0])
    layout = LAYOUTS["grocery"]
    assert cached.locate(parse_intent("durian"), "Acme", layout) is guess
    assert cached.locate(parse_intent("Durians"), "acme", layout) is guess
    assert inner.calls == 1
    now[0] = 61
    cached.locate(parse_intent("durian"), "Acme", layout)
    assert inner.calls == 2


def test_model_cache_does_not_store_failures():
    inner = CountingModel([None, None])
    cached = CachedLocationModel(inner)
    layout = LAYOUTS["grocery"]
    cached.locate(parse_intent("durian"), None, layout)
    cached.locate(parse_intent("durian"), None, layout)
    assert inner.calls == 2


def test_model_cache_evicts_oldest():
    guess = LocationGuess(category=None, department="Produce", source="model")
    inner = CountingModel([guess] * 3)
    cached = CachedLocationModel(inner, max_entries=1)
    layout = LAYOUTS["grocery"]
    cached.locate(parse_intent("durian"), None, layout)
    cached.locate(parse_intent("rambutan"), None, layout)
    cached.locate(parse_intent("durian"), None, layout)
    assert inner.calls == 3


def test_openapi_lists_all_routes():
    paths = set(app.openapi()["paths"])
    assert {
        "/health", "/stores/nearby", "/stores/search", "/stores/{store_id}", "/stores/{store_id}/zones",
        "/stores/{store_id}/layout",
        "/search", "/chat", "/identify", "/feedback", "/lists/parse", "/lists/scan",
        "/auth/phone/start", "/auth/phone/verify", "/auth/email/start", "/auth/email/verify",
        "/auth/apple", "/auth/google", "/auth/signout", "/me", "/me/phone/start", "/me/phone/verify", "/plus/status", "/plus/sync",
        "/plus/notifications",
        "/lists", "/lists/join", "/lists/{list_id}", "/lists/{list_id}/changes", "/route", "/route/multi", "/events",
    } == paths
