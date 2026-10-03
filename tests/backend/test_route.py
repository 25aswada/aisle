import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session

from backend.app.ai.catalog import layout_for_retailer
from backend.app.main import app
from backend.app.models import Store, StoreZone
from backend.app.routing import manhattan, order_points, path_length
from backend.app.seed import seed_store_zones

from conftest import store_id_for

LIST = ["milk", "eggs", "bananas", "toothpaste", "maple syrup", "frozen peas", "wine", "flux capacitor", "hammer"]


def _route(client, retailer, texts):
    store_id = store_id_for(client, retailer)
    items = [{"id": f"i{n}", "text": t} for n, t in enumerate(texts)]
    response = client.post("/route", json={"store_id": store_id, "items": items})
    assert response.status_code == 200, response.text
    return response.json()


def test_zone_coordinates_seeded(seeded_engine):
    with Session(seeded_engine) as session:
        zones = session.scalars(select(StoreZone)).all()
        assert zones and all(z.x is not None and z.y is not None for z in zones)
        assert all(0 <= z.x <= 1 and 0 <= z.y <= 1 for z in zones)
        store = session.scalar(select(Store).where(Store.name.like("Trader Joe's%")))
        assert (store.entrance_x, store.entrance_y) == layout_for_retailer("Trader Joe's").entrance


def test_seed_backfills_missing_coordinates_without_touching_verified(seeded_engine):
    with Session(seeded_engine) as session:
        store = session.scalar(select(Store).where(Store.name.like("Trader Joe's%")))
        template = session.scalar(select(StoreZone).where(StoreZone.store_id == store.id, StoreZone.name == "Frozen"))
        template.x = template.y = None
        session.add(StoreZone(store_id=store.id, name="Front Endcap", source="verified", sort_order=50))
        session.commit()
        seed_store_zones(session)
        session.refresh(template)
        assert (template.x, template.y) == (0.88, 0.60)
        verified = session.scalar(select(StoreZone).where(StoreZone.name == "Front Endcap"))
        assert verified.x is None


def test_route_groups_items_by_zone_and_orders_stops(seeded_client):
    data = _route(seeded_client, "Trader Joe's", LIST)
    departments = [s["department"] for s in data["stops"]]
    assert departments == [
        "Flowers & Produce", "Dairy & Eggs", "Breakfast/Pantry", "Frozen", "Wine & Beer", "Health & Household",
    ]
    assert [s["order"] for s in data["stops"]] == list(range(1, 7))
    dairy = data["stops"][1]
    assert [i["text"] for i in dairy["items"]] == ["milk", "eggs"]
    assert dairy["x"] is not None and dairy["zone_id"] is not None
    assert {(u["text"], u["reason"]) for u in data["unplaced"]} == {
        ("flux capacitor", "unknown"), ("hammer", "not_carried"),
    }
    placed = [i["id"] for s in data["stops"] for i in s["items"]] + [u["id"] for u in data["unplaced"]]
    assert sorted(placed) == sorted(f"i{n}" for n in range(len(LIST)))
    assert all(i["aisle"] is None for s in data["stops"] for i in s["items"])


def test_route_order_does_not_depend_on_list_order(seeded_client):
    forward = _route(seeded_client, "Trader Joe's", LIST)
    backward = _route(seeded_client, "Trader Joe's", list(reversed(LIST)))
    assert [s["department"] for s in forward["stops"]] == [s["department"] for s in backward["stops"]]


def test_route_is_no_longer_than_list_order(seeded_client):
    data = _route(seeded_client, "Target", ["ice cream", "bread", "toothpaste", "milk", "bananas", "dog food"])
    store_points = [(s["x"], s["y"]) for s in data["stops"]]
    layout = layout_for_retailer("Target")
    in_list_order = path_length(list(dict.fromkeys(store_points[::-1])), layout.entrance, layout.checkout)
    assert data["distance"] <= round(in_list_order, 3)


def test_database_aisles_show_in_route(seeded_client, seeded_engine):
    from backend.app.import_locations import import_rows

    store_id = store_id_for(seeded_client, "Target")
    with Session(seeded_engine) as session:
        import_rows(session, [{"store_id": str(store_id), "item": "ketchup", "source": "verified", "aisle": "G14"}])
    data = seeded_client.post("/route", json={"store_id": store_id, "items": [{"id": "a", "text": "ketchup"}]}).json()
    item = data["stops"][0]["items"][0]
    assert (item["aisle"], item["source"], item["confidence"]) == ("G14", "database", "high")


def test_zones_without_coordinates_go_last(seeded_client, seeded_engine):
    store_id = store_id_for(seeded_client, "Trader Joe's")
    with Session(seeded_engine) as session:
        zone = session.scalar(select(StoreZone).where(StoreZone.store_id == store_id, StoreZone.name == "Flowers & Produce"))
        zone.x = zone.y = None
        session.commit()
    data = _route(seeded_client, "Trader Joe's", ["bananas", "milk", "maple syrup"])
    assert data["stops"][-1]["department"] == "Flowers & Produce"
    assert data["stops"][-1]["x"] is None


def test_route_caps_model_calls(seeded_client):
    from backend.app.ai.providers import get_location_model

    class CountingModel:
        name = "counting"
        calls = 0

        def locate(self, intent, retailer_name, layout):
            CountingModel.calls += 1
            return None

    app.dependency_overrides[get_location_model] = lambda: CountingModel()
    _route(seeded_client, "Target", [f"mystery thing {n}" for n in range(12)])
    assert CountingModel.calls == 5


@pytest.mark.parametrize("body, status", [
    ({"store_id": 99999, "items": [{"id": "a", "text": "milk"}]}, 404),
    ({"store_id": 1, "items": []}, 422),
    ({"store_id": 1, "items": [{"id": "a", "text": ""}]}, 422),
    ({"store_id": 1, "items": [{"id": str(n), "text": "milk"} for n in range(101)]}, 422),
])
def test_route_validation(seeded_client, body, status):
    assert seeded_client.post("/route", json=body).status_code == status


def test_order_points_two_opt():
    points = [(0.0, 1.0), (1.0, 1.0), (0.0, 0.5), (1.0, 0.5)]
    order = order_points(points, (0.0, 0.0), (1.0, 0.0))
    assert path_length([points[i] for i in order], (0.0, 0.0), (1.0, 0.0)) == pytest.approx(3.0)  # up the left side, across, down the right
    assert manhattan((0, 0), (1, 1)) == 2
