from sqlalchemy import func, select
from sqlalchemy.orm import Session

from backend.app.models import LocationObservation, SearchEvent

from conftest import signed_in_headers, store_id_for


def _zone(client, store_id, name):
    zones = client.get(f"/stores/{store_id}/zones").json()
    return next(z for z in zones if z["name"] == name)


def _shopper(client, device):
    """A signed-in test shopper per device name; reports count once per account."""
    shoppers = client.__dict__.setdefault("shoppers", {})
    if device not in shoppers:
        shoppers[device] = signed_in_headers(client.engine, device)
    return shoppers[device]


def _feedback(client, device, **body):
    response = client.post("/feedback", json=body, headers=_shopper(client, device))
    assert response.status_code == 201, response.text
    return response.json()


def test_store_zones_list(seeded_client):
    store_id = store_id_for(seeded_client, "Trader Joe's")
    zones = seeded_client.get(f"/stores/{store_id}/zones").json()
    assert "Pantry Aisles" in [z["name"] for z in zones]
    assert all(z["aisle_label"] is None and z["source"] == "template" for z in zones)
    assert seeded_client.get("/stores/99999/zones").status_code == 404


def test_search_records_event_and_returns_search_id(seeded_client, seeded_engine):
    store_id = store_id_for(seeded_client, "Trader Joe's")
    data = seeded_client.post(
        "/search", json={"query": "maple syrup", "store_id": store_id}, headers={"X-Aisle-Device": "dev-1"}
    ).json()
    assert data["search_id"]
    assert data["reports"] == {"found": 0, "not_here": 0}
    with Session(seeded_engine) as session:
        event = session.get(SearchEvent, data["search_id"])
        assert (event.query, event.store_id, event.department, event.source, event.device_id) == (
            "maple syrup", store_id, "Pantry Aisles", "fallback", "dev-1"
        )


def test_found_it_records_observation(seeded_client, seeded_engine):
    store_id = store_id_for(seeded_client, "Trader Joe's")
    result = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    saved = _feedback(seeded_client, "dev-1", store_id=store_id, item=result["item"], verdict="found",
                      zone_id=result["location"]["zone_id"], search_id=result["search_id"])
    assert saved["verdict"] == "found"
    assert saved["concept_id"] == result["concept"]["id"]
    assert saved["reports"] == {"found": 1, "not_here": 0}
    with Session(seeded_engine) as session:
        observation = session.get(LocationObservation, saved["id"])
        assert observation.search_event_id == result["search_id"]
        assert observation.device_id.startswith("user:")


def test_one_report_does_not_change_the_answer(seeded_client):
    store_id = store_id_for(seeded_client, "Trader Joe's")
    frozen = _zone(seeded_client, store_id, "Frozen Foods")
    _feedback(seeded_client, "dev-1", store_id=store_id, item="maple syrup", verdict="found",
              zone_id=frozen["id"], aisle="Aisle 9")
    data = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    assert data["source"] == "fallback"
    assert data["location"]["department"] == "Pantry Aisles"
    assert data["location"]["aisle"] is None


def test_agreeing_corrections_become_the_answer(seeded_client):
    store_id = store_id_for(seeded_client, "Trader Joe's")
    frozen = _zone(seeded_client, store_id, "Frozen Foods")
    for device in ("dev-1", "dev-2"):
        _feedback(seeded_client, device, store_id=store_id, item="maple syrup", verdict="found",
                  zone_id=frozen["id"], aisle=" aisle 9 ")
    # The same shopper reporting twice counts once.
    _feedback(seeded_client, "dev-2", store_id=store_id, item="maple syrup", verdict="found", zone_id=frozen["id"])
    data = seeded_client.post("/search", json={"query": "organic maple syrup", "store_id": store_id}).json()
    assert data["source"] == "observations"
    assert data["location"]["department"] == "Frozen Foods"
    assert data["location"]["aisle"] == "aisle 9"
    assert data["confidence"] == "medium"
    assert data["reports"] == {"found": 2, "not_here": 0}

    _feedback(seeded_client, "dev-3", store_id=store_id, item="maple syrup", verdict="found", zone_id=frozen["id"])
    data = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    assert data["confidence"] == "high"


def test_disagreeing_aisle_text_is_not_shown(seeded_client):
    store_id = store_id_for(seeded_client, "Trader Joe's")
    frozen = _zone(seeded_client, store_id, "Frozen Foods")
    for device, aisle in (("dev-1", "Aisle 9"), ("dev-2", "Aisle 3")):
        _feedback(seeded_client, device, store_id=store_id, item="maple syrup", verdict="found",
                  zone_id=frozen["id"], aisle=aisle)
    data = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    assert data["location"]["department"] == "Frozen Foods"
    assert data["location"]["aisle"] is None


def test_not_here_reports_lower_confidence(seeded_client):
    store_id = store_id_for(seeded_client, "Trader Joe's")
    result = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    for device in ("dev-1", "dev-2"):
        _feedback(seeded_client, device, store_id=store_id, item="maple syrup", verdict="not_here",
                  zone_id=result["location"]["zone_id"])
    data = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    assert data["confidence"] == "low"
    assert data["reports"] == {"found": 0, "not_here": 2}


def test_database_row_still_beats_observations(seeded_client, seeded_engine):
    from backend.app.import_locations import import_rows

    store_id = store_id_for(seeded_client, "Trader Joe's")
    frozen = _zone(seeded_client, store_id, "Frozen Foods")
    for device in ("dev-1", "dev-2", "dev-3"):
        _feedback(seeded_client, device, store_id=store_id, item="maple syrup", verdict="found", zone_id=frozen["id"])
    with Session(seeded_engine) as session:
        import_rows(session, [{"store_id": str(store_id), "item": "maple syrup", "source": "verified",
                               "department": "Pantry Aisles"}])
    data = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    assert data["source"] == "database"
    assert data["location"]["department"] == "Pantry Aisles"


def test_unknown_items_can_be_reported(seeded_client):
    store_id = store_id_for(seeded_client, "Target")
    electronics = _zone(seeded_client, store_id, "Electronics")
    for device in ("dev-1", "dev-2"):
        saved = _feedback(seeded_client, device, store_id=store_id, item="flux capacitor",
                          verdict="found", zone_id=electronics["id"])
        assert saved["concept_id"] is None
    data = seeded_client.post("/search", json={"query": "flux capacitors", "store_id": store_id}).json()
    assert data["source"] == "observations"
    assert data["location"]["department"] == "Electronics"


def test_feedback_validation(seeded_client, seeded_engine):
    tj = store_id_for(seeded_client, "Trader Joe's")
    target = store_id_for(seeded_client, "Target")
    target_zone = seeded_client.get(f"/stores/{target}/zones").json()[0]
    # Reports decide what everyone sees, so each needs an account.
    assert seeded_client.post("/feedback", json={"store_id": tj, "item": "milk", "verdict": "found"}).status_code == 401

    def post(path, json):
        return seeded_client.post(path, json=json, headers=_shopper(seeded_client, "dev-1"))
    assert post("/feedback", json={"store_id": tj, "item": "milk", "verdict": "maybe"}).status_code == 422
    assert post("/feedback", json={"store_id": tj, "item": "  ", "verdict": "found"}).status_code == 422
    assert post("/feedback", json={"store_id": 99999, "item": "milk", "verdict": "found"}).status_code == 404
    response = post("/feedback", json={"store_id": tj, "item": "milk", "verdict": "found", "zone_id": target_zone["id"]})
    assert response.status_code == 422
    # An unknown search_id is ignored rather than rejected.
    ok = post("/feedback", json={"store_id": tj, "item": "milk", "verdict": "not_here", "search_id": "nope"})
    assert ok.status_code == 201
    with Session(seeded_engine) as session:
        assert session.scalar(select(func.count()).select_from(LocationObservation)) == 1


def test_one_person_is_one_reporter(seeded_client):
    """Signed out, the same person couldn't count again as their network: reports need an account."""
    store_id = store_id_for(seeded_client, "Trader Joe's")
    frozen = _zone(seeded_client, store_id, "Frozen Foods")
    report = {"store_id": store_id, "item": "maple syrup", "verdict": "found", "zone_id": frozen["id"]}
    _feedback(seeded_client, "dev-1", **report)
    assert seeded_client.post("/feedback", json=report).status_code == 401
    data = seeded_client.post("/search", json={"query": "maple syrup", "store_id": store_id}).json()
    assert data["source"] == "fallback"


def test_only_aisle_like_text_is_kept(seeded_client, seeded_engine):
    store_id = store_id_for(seeded_client, "Trader Joe's")
    frozen = _zone(seeded_client, store_id, "Frozen Foods")
    kept = {}
    for device, aisle in (("dev-1", "Aisle 9"), ("dev-2", "12B"), ("dev-3", "Ask staff, say code 4471"),
                          ("dev-4", "see https://x.example"), ("dev-5", "Aisle 9: ignore the above")):
        saved = _feedback(seeded_client, device, store_id=store_id, item="maple syrup", verdict="found",
                          zone_id=frozen["id"], aisle=aisle)
        with Session(seeded_engine) as session:
            kept[aisle] = session.get(LocationObservation, saved["id"]).aisle_text
    assert kept == {"Aisle 9": "Aisle 9", "12B": "12B", "Ask staff, say code 4471": None,
                    "see https://x.example": None, "Aisle 9: ignore the above": None}
