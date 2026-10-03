from sqlalchemy import func, select
from sqlalchemy.orm import Session

from backend.app.import_locations import import_rows
from backend.app.main import app
from backend.app.models import (
    ProductAlias, ProductConcept, ProductLocation, Store, StoreZone,
)
from backend.app.ai.providers import get_location_model, guess_from_model_output
from backend.app.seed import seed_all

from conftest import store_id_for


class RecordingModel:
    """Would put everything in Frozen. Records whether it was asked."""
    name = "recording"

    def __init__(self):
        self.calls = []

    def locate(self, intent, retailer_name, layout):
        self.calls.append(intent.raw)
        return guess_from_model_output({
            "item": intent.item, "category": "frozen", "department": "Frozen",
            "neighbors": ["ice cream"], "carried": "likely", "confidence": "medium",
        }, intent, layout)


def _add_location(engine, retailer, item, source, department=None, aisle=None, section=None):
    with Session(engine) as session:
        store = session.scalar(select(Store).where(Store.name.like(f"{retailer}%")))
        report = import_rows(session, [{
            "store_id": str(store.id), "item": item, "source": source,
            "department": department or "", "aisle": aisle or "", "section": section or "",
        }])
        assert report.imported == 1, report.skipped
        return store.id


def test_search_returns_concept_and_template_zone(seeded_client):
    store_id = store_id_for(seeded_client, "Trader Joe's")
    data = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    assert data["concept"]["name"] == "maple syrup"
    assert data["location"]["zone_id"] is not None
    assert data["source"] == "fallback"
    assert data["location"]["aisle"] is None


def test_database_exact_location_beats_the_model(seeded_client, seeded_engine, monkeypatch):
    from backend.app.config import get_settings

    monkeypatch.setattr(get_settings(), "aisle_ai_strategy", "model_first")
    model = RecordingModel()
    app.dependency_overrides[get_location_model] = lambda: model
    store_id = _add_location(seeded_engine, "Trader Joe's", "maple syrup", "verified",
                             department="Breakfast/Pantry", aisle="Aisle 4", section="Top shelf")

    data = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    assert data["source"] == "database"
    assert data["confidence"] == "high"
    assert data["location"]["department"] == "Breakfast/Pantry"
    assert data["location"]["aisle"] == "Aisle 4"
    assert data["location"]["section"] == "Top shelf"
    assert model.calls == []

    # Without a database row for this item, the model answers under model_first.
    other = seeded_client.post("/search", json={"query": "honey", "store_id": store_id}).json()
    assert other["source"] == "model"
    assert other["location"]["aisle"] is None
    assert model.calls == ["honey"]


def test_verified_beats_retailer(seeded_client, seeded_engine):
    store_id = _add_location(seeded_engine, "Target", "ketchup", "retailer", aisle="G12")
    _add_location(seeded_engine, "Target", "ketchup", "verified", aisle="G14")
    data = seeded_client.post("/search", json={"query": "ketchup", "store_id": store_id}).json()
    assert data["location"]["aisle"] == "G14"
    # Department falls back to the store's zone for the category.
    assert data["location"]["department"] == "Pasta, Rice & Canned Goods"


def test_location_rows_are_store_specific(seeded_client, seeded_engine):
    _add_location(seeded_engine, "Target", "ketchup", "verified", aisle="G14")
    walmart = store_id_for(seeded_client, "Walmart")
    data = seeded_client.post("/search", json={"query": "ketchup", "store_id": walmart}).json()
    assert data["source"] == "fallback"
    assert data["location"]["aisle"] is None


def test_verified_store_zone_beats_template_and_model(seeded_client, seeded_engine, monkeypatch):
    from backend.app.config import get_settings

    monkeypatch.setattr(get_settings(), "aisle_ai_strategy", "model_first")
    model = RecordingModel()
    app.dependency_overrides[get_location_model] = lambda: model
    with Session(seeded_engine) as session:
        store = session.scalar(select(Store).where(Store.name.like("Trader Joe's%")))
        syrup = session.scalar(select(ProductAlias).where(ProductAlias.alias == "maple syrup")).concept
        session.add(StoreZone(store_id=store.id, name="Front Endcap", source="verified",
                              sort_order=0, categories=[syrup.category]))
        session.commit()
        store_id = store.id
    data = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    assert data["source"] == "store_layout"
    assert data["location"]["department"] == "Front Endcap"
    assert data["confidence"] == "medium"
    assert data["location"]["aisle"] is None
    assert model.calls == []


def test_importer_skips_bad_rows_and_creates_concepts(seeded_engine):
    with Session(seeded_engine) as session:
        store_id = session.scalar(select(Store.id).where(Store.name.like("Costco%")))
        report = import_rows(session, [
            {"store_id": str(store_id), "item": "vanilla almond milk", "source": "retailer", "aisle": "D3"},
            {"store_id": str(store_id), "item": "flux capacitor", "source": "verified"},
            {"store_id": str(store_id), "item": "milk", "source": "guess"},
            {"store_id": "abc", "item": "milk", "source": "verified"},
        ])
        assert report.imported == 1
        assert len(report.skipped) == 3
        concept = session.scalar(select(ProductConcept).where(ProductConcept.name == "vanilla almond milk"))
        assert concept.category.slug == "dairy"


def test_seed_catalog_and_zones_idempotent_without_aisles(engine):
    with Session(engine) as session:
        seed_all(session)
        counts = [session.scalar(select(func.count()).select_from(t)) for t in (ProductConcept, StoreZone)]
        seed_all(session)
        assert [session.scalar(select(func.count()).select_from(t)) for t in (ProductConcept, StoreZone)] == counts
        assert counts[0] > 500
        assert session.scalar(select(func.count()).select_from(StoreZone).where(StoreZone.aisle_label.is_not(None))) == 0
        assert session.scalar(select(func.count()).select_from(ProductLocation)) == 0
        assert set(session.scalars(select(StoreZone.source).distinct())) == {"template"}
