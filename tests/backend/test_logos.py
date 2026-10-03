from urllib.parse import parse_qs, urlsplit

from sqlalchemy import select
from sqlalchemy.orm import Session

from backend.app.config import get_settings
from backend.app.logos import logo_url
from backend.app.models import Retailer
from backend.app.seed import seed_stores
from conftest import store_id_for


def test_no_key_means_no_logo(monkeypatch):
    monkeypatch.setattr(get_settings(), "logo_dev_publishable_key", None)
    assert logo_url("target.com") is None


def test_logo_url_uses_publishable_key_and_404_fallback(monkeypatch):
    monkeypatch.setattr(get_settings(), "logo_dev_publishable_key", "pk_test")
    url = urlsplit(logo_url(" Target.com "))
    assert (url.scheme, url.netloc, url.path) == ("https", "img.logo.dev", "/target.com")
    query = parse_qs(url.query)
    assert query["token"] == ["pk_test"]
    assert query["fallback"] == ["404"]
    assert logo_url(None) is None


def test_store_responses_include_logo(seeded_client, monkeypatch):
    monkeypatch.setattr(get_settings(), "logo_dev_publishable_key", "pk_test")
    store_id = store_id_for(seeded_client, "Target")
    detail = seeded_client.get(f"/stores/{store_id}").json()
    assert detail["retailer"]["domain"] == "target.com"
    assert detail["retailer_logo_url"].startswith("https://img.logo.dev/target.com?")
    nearby = seeded_client.get("/stores/nearby", params={"lat": 39.95, "lon": -75.16}).json()
    assert all(s["retailer_logo_url"] for s in nearby["stores"])

    monkeypatch.setattr(get_settings(), "logo_dev_publishable_key", None)
    assert seeded_client.get(f"/stores/{store_id}").json()["retailer_logo_url"] is None


def test_seed_backfills_domain_without_overwriting(engine):
    with Session(engine) as session:
        seed_stores(session)
        target = session.scalar(select(Retailer).where(Retailer.name == "Target"))
        assert target.domain == "target.com"
        target.domain = "target.example"
        session.commit()
        seed_stores(session)
        assert session.scalar(select(Retailer.domain).where(Retailer.name == "Target")) == "target.example"
