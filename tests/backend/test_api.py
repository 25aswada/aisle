import pytest
from fastapi.testclient import TestClient

from backend.app.database import get_db
from backend.app.main import app


def test_health_does_not_need_database():
    def unexpected_database_access():
        raise AssertionError("Health must not access the database")

    app.dependency_overrides[get_db] = unexpected_database_access
    try:
        with TestClient(app) as client:
            response = client.get("/health")
        assert response.status_code == 200
        assert response.json() == {"status": "ok"}
    finally:
        app.dependency_overrides.clear()


def test_nearby_order_distance_and_limit(client):
    response = client.get("/stores/nearby", params={"lat": 40, "lon": -75, "limit": 2})
    assert response.status_code == 200
    data = response.json()
    assert data["message"] is None
    assert [s["name"] for s in data["stores"]] == ["Near Store", "Middle Store"]
    assert data["stores"][0]["distance_miles"] == 0
    assert data["stores"][1]["distance_miles"] == pytest.approx(69.0934, rel=0.001)
    assert data["stores"][0]["retailer"]["name"] == "Trader Joe's"


@pytest.mark.parametrize("params", [{}, {"lat": 40}, {"lon": -75}])
def test_missing_coordinates_returns_empty_list_without_database(params):
    class NoQueries:
        def scalars(self, *_):
            raise AssertionError("Missing coordinates must not query stores")

    app.dependency_overrides[get_db] = lambda: NoQueries()
    try:
        with TestClient(app) as client:
            response = client.get("/stores/nearby", params=params)
        assert response.status_code == 200
        assert response.json()["stores"] == []
        assert response.json()["message"]
    finally:
        app.dependency_overrides.clear()


@pytest.mark.parametrize("q, names", [
    ("nEaR", ["Near Store"]),
    (" market ", ["Middle Store", "Near Store"]),
    ("TRADER JOE'S", ["Far Store", "Middle Store", "Near Store"]),
    ("no matching location", []),
    ("%", []),
    ("_", []),
    ("  ", []),
])
def test_manual_search(client, q, names):
    response = client.get("/stores/search", params={"q": q})
    assert response.status_code == 200
    assert [s["name"] for s in response.json()] == names


def test_store_detail_and_not_found(client):
    store = client.get("/stores/search", params={"q": "Near"}).json()[0]
    response = client.get(f"/stores/{store['id']}")
    assert response.status_code == 200
    assert response.json() == store
    assert store["external_place_id"] is None
    assert store["store_number"] is None
    assert client.get("/stores/99999").status_code == 404


@pytest.mark.parametrize("params", [
    {"lat": 91, "lon": 0}, {"lat": 0, "lon": -181},
    {"lat": "nan", "lon": 0}, {"lat": 0, "lon": "inf"},
    {"lat": 0, "lon": 0, "limit": 0}, {"lat": 0, "lon": 0, "limit": 101},
])
def test_nearby_validates_input(client, params):
    assert client.get("/stores/nearby", params=params).status_code == 422


def test_empty_database(engine):
    from sqlalchemy.orm import Session

    def override_db():
        with Session(engine) as session:
            yield session

    app.dependency_overrides[get_db] = override_db
    try:
        with TestClient(app) as client:
            assert client.get("/stores/nearby?lat=40&lon=-75").json()["stores"] == []
            assert client.get("/stores/search?q=Costco").json() == []
    finally:
        app.dependency_overrides.clear()


def test_store_payload_matches_ios_contract(client):
    """iOS decodes `retailer_name` and a numeric or string `id`."""
    nearby = client.get("/stores/nearby", params={"lat": 40, "lon": -75}).json()["stores"]
    searched = client.get("/stores/search", params={"q": "Near"}).json()
    for store in (nearby[0], searched[0]):
        assert store["retailer_name"] == "Trader Joe's"
        assert isinstance(store["id"], int)
