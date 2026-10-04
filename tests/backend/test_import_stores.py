import json
import random

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from backend.app import import_stores
from backend.app.ai.catalog import layout_for_retailer
from backend.app.database import get_db
from backend.app.import_stores import CHAINS, ImportReport, load, records_from, to_record
from backend.app.main import app, distance_miles
from backend.app.models import Retailer, Store, StoreZone
from backend.app.seed import seed_all

CHAIN = {c.name: c for c in CHAINS}


def osm(id, lat, lon, kind="node", **tags):
    """An Overpass element; ways carry a center point."""
    tags = {key.replace("__", ":"): value for key, value in tags.items()}
    element = {"type": kind, "id": id, "tags": tags}
    if kind == "node":
        element.update(lat=lat, lon=lon)
    else:
        element["center"] = {"lat": lat, "lon": lon}
    return element


def walmart(id, lat=41.3099, lon=-81.5194, kind="way", **extra):
    tags = dict(shop="supermarket", name="Walmart Supercenter", ref="1927",
                addr__housenumber="8160", addr__street="Macedonia Commons Boulevard",
                addr__city="Macedonia", addr__state="OH", addr__postcode="44056")
    tags.update(extra)
    return osm(id, lat, lon, kind, **tags)


def giant_eagle(id, lat, lon, city, number):
    return osm(id, lat, lon, "way", shop="supermarket", name="Giant Eagle", ref=number,
               addr__housenumber="100", addr__street="Main Street", addr__city=city,
               addr__state="OH", addr__postcode="44147")


def download(**chains):
    return {"bbox": None, "chains": {CHAIN[name.replace("_s", "'s").replace("_", " ")].name: elements for name, elements in chains.items()}}


def import_download(session, data, bbox=None, prune=False):
    chains = [CHAIN[name] for name in data["chains"]]
    return load(session, records_from(data, chains, ImportReport()), chains, bbox, prune)


@pytest.fixture
def db_client(engine):
    def override_db():
        with Session(engine) as session:
            yield session

    app.dependency_overrides[get_db] = override_db
    with TestClient(app) as client:
        yield client
    app.dependency_overrides.clear()


@pytest.mark.parametrize("chain", CHAINS, ids=lambda c: c.name)
def test_every_chain_gets_its_intended_store_map(chain):
    assert layout_for_retailer(chain.name).key == chain.layout


def test_chains_are_distinct():
    assert len({c.name for c in CHAINS}) == len(CHAINS)
    ids = [qid for c in CHAINS for qid in c.wikidata]
    assert len(ids) == len(set(ids))


def test_record_from_a_walmart():
    record, reason = to_record(CHAIN["Walmart"], walmart(86818680))
    assert reason is None
    assert record.osm_id == "osm:way/86818680"
    assert record.name == "Walmart Supercenter Macedonia"
    assert record.address == "8160 Macedonia Commons Boulevard, Macedonia, OH 44056"
    assert record.store_number == "1927"
    assert (record.latitude, record.longitude) == (41.3099, -81.5194)


@pytest.mark.parametrize("chain, tags, reason", [
    ("Walmart", {"amenity": "fuel"}, "not the store itself"),
    ("Kroger", {"amenity": "pharmacy"}, "not the store itself"),
    ("Walmart", {"shop": "car_repair"}, "not the store itself"),
    ("Walmart", {"shop": "supermarket", "disused": "yes"}, "closed"),
])
def test_objects_that_are_not_stores_are_skipped(chain, tags, reason):
    element = osm(1, 41, -81, **tags)
    element["tags"].update({"addr:city": "Parma", "addr:state": "OH"})
    record, why = to_record(CHAIN[chain], element)
    assert record is None and why.startswith(reason)


def test_pharmacy_chains_accept_pharmacy_tags():
    element = osm(5, 41.31, -81.67, amenity="pharmacy", name="CVS Pharmacy", branch="Broadview Heights",
                  addr__city="Broadview Heights", addr__state="OH")
    record, _ = to_record(CHAIN["CVS"], element)
    assert record.name == "CVS Pharmacy Broadview Heights"
    assert record.address == "Broadview Heights, OH"


def test_names_fall_back_to_the_chain():
    element = osm(6, 41, -81, shop="supermarket", name="Store #4021", addr__city="Parma")
    assert to_record(CHAIN["Giant Eagle"], element)[0].name == "Giant Eagle Parma"
    element = osm(7, 41, -81, shop="doityourself", name="The Home Depot", addr__city="Parma")
    assert to_record(CHAIN["Home Depot"], element)[0].name == "The Home Depot Parma"


def test_a_building_and_a_point_for_one_store_merge():
    report = ImportReport()
    point = osm(1, 41.30995, -81.51945, "node", shop="supermarket", name="Walmart", addr__city="Macedonia")
    records = records_from(download(Walmart=[point, walmart(2)]), [CHAIN["Walmart"]], report)
    assert report.duplicates == 1
    assert [r.osm_id for r in records] == ["osm:way/2"]  # The fuller address wins.
    far = walmart(3, lat=41.40)
    assert len(records_from(download(Walmart=[walmart(2), far]), [CHAIN["Walmart"]], ImportReport())) == 2


def test_import_creates_stores_and_reruns_change_nothing(engine):
    data = download(Walmart=[walmart(2)], Giant_Eagle=[
        giant_eagle(10, 41.32, -81.66, "Broadview Heights", "6337"),
        giant_eagle(11, 41.31, -81.83, "Strongsville", "6309"),
    ])
    with Session(engine) as session:
        first = import_download(session, data)
        assert (first.created, first.updated) == (3, 0)
        ids = sorted(session.scalars(select(Store.id)))
        again = import_download(session, data)
        assert (again.created, again.updated, again.unchanged) == (0, 0, 3)
        assert sorted(session.scalars(select(Store.id))) == ids
        retailer = session.scalar(select(Retailer).where(Retailer.name == "Giant Eagle"))
        assert retailer.domain == "gianteagle.com"


def test_a_store_keeps_its_id_when_osm_redraws_it(engine):
    with Session(engine) as session:
        import_download(session, download(Walmart=[walmart(2)]))
        store_id = session.scalar(select(Store.id))
        # Same store number, new OSM object 400 m away (the outline was redrawn).
        report = import_download(session, download(Walmart=[walmart(99, lat=41.3135)]))
        assert (report.created, report.updated) == (0, 1)
        store = session.get(Store, store_id)
        assert store.external_place_id == "osm:way/99" and store.latitude == 41.3135
        # No store number: matched by being the same chain a few meters away.
        report = import_download(session, download(Walmart=[walmart(100, lat=41.3136, ref="")]))
        assert (report.created, report.updated) == (0, 1)
        assert session.scalar(select(func.count()).select_from(Store)) == 1


def test_demo_stores_become_the_real_store(engine):
    with Session(engine) as session:
        seed_all(session)
        demo = session.scalar(select(Store).where(Store.name == "Target Washington Square"))
        target = osm(500, demo.latitude + 0.0004, demo.longitude, "way", shop="department_store", name="Target",
                     addr__housenumber="1128", addr__street="Chestnut Street", addr__city="Philadelphia",
                     addr__state="PA", addr__postcode="19107", branch="Washington Square")
        report = import_download(session, download(Target=[target]))
        assert (report.created, report.updated) == (0, 1)
        session.refresh(demo)
        assert demo.name == "Target Washington Square"
        assert demo.external_place_id == "osm:way/500"


def test_stores_gone_from_osm_are_only_deleted_with_prune(engine):
    ohio = (40.5, -82.0, 41.6, -81.0)
    with Session(engine) as session:
        import_download(session, download(Giant_Eagle=[
            giant_eagle(10, 41.32, -81.66, "Broadview Heights", "6337"),
            giant_eagle(11, 41.31, -81.83, "Strongsville", "6309"),
            giant_eagle(12, 40.44, -79.99, "Pittsburgh", "0001"),  # Outside the box.
        ]))
        later = download(Giant_Eagle=[giant_eagle(10, 41.32, -81.66, "Broadview Heights", "6337")])
        report = import_download(session, later, bbox=ohio)
        assert len(report.stale) == 1 and "Strongsville" in report.stale[0]
        assert session.scalar(select(func.count()).select_from(Store)) == 3
        report = import_download(session, later, bbox=ohio, prune=True)
        assert report.pruned == 1
        assert sorted(session.scalars(select(Store.address))) == [
            "100 Main Street, Broadview Heights, OH 44147", "100 Main Street, Pittsburgh, OH 44147",
        ]


def test_imported_stores_get_their_chain_map_on_first_use(engine, db_client):
    with Session(engine) as session:
        seed_all(session)  # Categories, which zones link to.
        import_download(session, download(Walmart=[walmart(2)]))
        store_id = session.scalar(select(Store.id).where(Store.external_place_id == "osm:way/2"))
        assert session.scalar(select(func.count()).where(StoreZone.store_id == store_id)) == 0

    layout = db_client.get(f"/stores/{store_id}/layout").json()
    walmart_layout = layout_for_retailer("Walmart")
    assert [z["name"] for z in layout["zones"]] == [z.name for z in walmart_layout.zones]
    assert (layout["entrance"]["x"], layout["entrance"]["y"]) == walmart_layout.entrance
    assert db_client.get(f"/stores/{store_id}/layout").json()["zones"] == layout["zones"]

    found = db_client.post("/search", json={"query": "milk", "store_id": store_id}).json()
    assert found["location"]["department"] == "Dairy"
    route = db_client.post("/route", json={"store_id": store_id, "items": [{"id": "1", "text": "eggs"}]})
    assert route.status_code == 200 and route.json()["stops"]


def test_command_line_loads_a_saved_download(engine, tmp_path, monkeypatch, capsys):
    path = tmp_path / "stores.json"
    path.write_text(json.dumps(download(Walmart=[walmart(2), osm(3, 41, -81, amenity="fuel")])))
    monkeypatch.setattr(import_stores, "get_engine", lambda: engine)
    import_stores.main(["--from-file", str(path), "--dry-run"])
    assert "Created 1" in capsys.readouterr().out
    with Session(engine) as session:
        assert session.scalar(select(func.count()).select_from(Store)) == 0
    import_stores.main(["--from-file", str(path)])
    with Session(engine) as session:
        assert session.scalar(select(Store.name)) == "Walmart Supercenter Macedonia"


def _many_stores(session, count, seed=7):
    rng = random.Random(seed)
    retailer = Retailer(name="Aldi")
    session.add(retailer)
    session.flush()
    stores = [
        Store(retailer_id=retailer.id, name=f"Aldi {n}", address=f"{n} Main St",
              latitude=rng.uniform(25, 49), longitude=rng.uniform(-124, -67))
        for n in range(count)
    ]
    session.add_all(stores)
    session.commit()


@pytest.mark.parametrize("lat, lon, limit", [
    (41.3134, -81.6668, 20),   # Broadview Heights
    (39.9526, -75.1652, 5),
    (47.6, -122.3, 100),
    (64.8, -147.7, 3),         # Fairbanks: nothing for hundreds of miles
    (-33.9, 151.2, 1),         # Sydney: every store is thousands of miles away
])
def test_nearby_matches_checking_every_store(engine, db_client, lat, lon, limit):
    with Session(engine) as session:
        _many_stores(session, 2000)
        everything = sorted(session.scalars(select(Store)), key=lambda s: (distance_miles(lat, lon, s), s.id))
        expected = [s.id for s in everything[:limit]]
    stores = db_client.get("/stores/nearby", params={"lat": lat, "lon": lon, "limit": limit}).json()["stores"]
    assert [s["id"] for s in stores] == expected


def test_nearby_across_the_antimeridian(engine, db_client):
    with Session(engine) as session:
        retailer = Retailer(name="Walmart")
        session.add(retailer)
        session.flush()
        session.add_all([
            Store(retailer_id=retailer.id, name="East", address="1", latitude=0, longitude=179.99),
            Store(retailer_id=retailer.id, name="West", address="2", latitude=0, longitude=-179.99),
            Store(retailer_id=retailer.id, name="Far", address="3", latitude=0, longitude=170),
        ])
        session.commit()
    for lon in (179.995, -179.995):
        stores = db_client.get("/stores/nearby", params={"lat": 0, "lon": lon, "limit": 2}).json()["stores"]
        assert {s["name"] for s in stores} == {"East", "West"}
        assert all(s["distance_miles"] < 2 for s in stores)


def test_store_search_matches_every_word_and_ranks_by_distance(engine, db_client):
    with Session(engine) as session:
        import_download(session, download(Giant_Eagle=[
            giant_eagle(10, 41.32, -81.66, "Broadview Heights", "6337"),
            giant_eagle(11, 41.31, -81.83, "Strongsville", "6309"),
            giant_eagle(12, 40.44, -79.99, "Pittsburgh", "0001"),
        ]))
    names = lambda response: [s["name"] for s in response.json()]
    assert names(db_client.get("/stores/search", params={"q": "giant eagle strongsville"})) == \
        ["Giant Eagle Strongsville"]
    near_pittsburgh = db_client.get("/stores/search", params={"q": "Giant Eagle", "lat": 40.44, "lon": -80.0})
    assert names(near_pittsburgh)[0] == "Giant Eagle Pittsburgh"
    assert near_pittsburgh.json()[0]["distance_miles"] < 1
    assert names(db_client.get("/stores/search", params={"q": "giant", "limit": 1})) == \
        ["Giant Eagle Broadview Heights"]


def test_fetching_splits_a_batch_by_chain(monkeypatch):
    asked = []

    def fake_fetch(chains, bbox, url):
        asked.append([c.name for c in chains])
        wanted = {qid for c in chains for qid in c.wikidata}
        elements = [
            walmart(1, **{"brand:wikidata": "Q483551"}),
            osm(2, 41, -81, shop="supermarket", **{"brand:wikidata": "Q1522721"}),
            osm(3, 41, -81, shop="supermarket", **{"brand:wikidata": "Q483551;Q1522721"}),
        ]
        return [e for e in elements if e["tags"]["brand:wikidata"] in wanted]

    monkeypatch.setattr(import_stores, "fetch_elements", fake_fetch)
    monkeypatch.setattr(import_stores, "CHAINS_PER_QUERY", 1)
    chains = [CHAIN["Walmart"], CHAIN["Giant Eagle"]]
    data = import_stores.fetch_all(chains, None)
    assert asked == [["Walmart"], ["Giant Eagle"]]
    assert [e["id"] for e in data["chains"]["Walmart"]] == [1]
    assert [e["id"] for e in data["chains"]["Giant Eagle"]] == [2]


def test_a_saved_download_resumes_where_it_stopped(monkeypatch, tmp_path):
    asked = []
    monkeypatch.setattr(import_stores, "fetch_elements",
                        lambda chains, bbox, url: asked.append([c.name for c in chains]) or [])
    path = str(tmp_path / "stores.json")
    with open(path, "w") as handle:
        json.dump({"bbox": None, "chains": {"Walmart": [walmart(1)]}}, handle)
    data = import_stores.fetch_all([CHAIN["Walmart"], CHAIN["Target"]], None, save=path)
    assert asked == [["Target"]]
    assert [e["id"] for e in data["chains"]["Walmart"]] == [1]
    with open(path) as handle:
        assert set(json.load(handle)["chains"]) == {"Walmart", "Target"}


def test_stores_without_an_address_are_placed_by_the_nearest_town():
    report = ImportReport()
    bare = osm(20, 41.32, -81.67, amenity="pharmacy", name="CVS Pharmacy")
    lonely = osm(21, 44.0, -100.0, amenity="pharmacy", name="CVS Pharmacy")
    records = records_from(download(CVS=[bare, lonely], Giant_Eagle=[
        giant_eagle(10, 41.32, -81.66, "Broadview Heights", "6337"),
    ]), [CHAIN["CVS"], CHAIN["Giant Eagle"]], report)
    cvs = next(r for r in records if r.chain.name == "CVS")
    assert (cvs.name, cvs.address) == ("CVS Pharmacy", "Near Broadview Heights, OH")
    assert len(records) == 2
    assert report.skipped == {"no address, and no town nearby": 1}


def test_neighboring_stores_with_different_addresses_stay_apart():
    # Two Walgreens a block apart in a city: different house numbers, so two stores.
    a = osm(30, 40.7500, -73.9900, shop="chemist", addr__housenumber="1", addr__street="Broadway",
            addr__city="New York", addr__state="NY")
    b = osm(31, 40.7505, -73.9900, shop="chemist", addr__housenumber="99", addr__street="Broadway",
            addr__city="New York", addr__state="NY")
    report = ImportReport()
    assert len(records_from(download(Walgreens=[a, b]), [CHAIN["Walgreens"]], report)) == 2
    assert report.duplicates == 0


def test_demo_stores_with_rough_coordinates_match_on_their_street(engine):
    with Session(engine) as session:
        seed_all(session)
        demo = session.scalar(select(Store).where(Store.name == "Costco King of Prussia"))
        costco = osm(600, demo.latitude + 0.003, demo.longitude, "way", shop="wholesale", name="Costco",
                     addr__housenumber="201", addr__street="Allendale Road", addr__city="King of Prussia",
                     addr__state="PA", addr__postcode="19406")
        across_town = osm(601, demo.latitude - 0.003, demo.longitude, "way", shop="wholesale", name="Costco",
                          addr__housenumber="5", addr__street="Main Street", addr__city="King of Prussia",
                          addr__state="PA")
        report = import_download(session, download(Costco=[across_town, costco]))
        assert (report.created, report.updated) == (1, 1)
        session.refresh(demo)
        assert demo.external_place_id == "osm:way/600"
        assert demo.address == "201 Allendale Road, King of Prussia, PA 19406"


def test_a_missing_state_comes_from_a_neighbor_in_the_same_town():
    walgreens = osm(40, 41.30, -81.65, shop="chemist", name="Walgreens", addr__housenumber="8966",
                    addr__street="Brecksville Road", addr__city="Brecksville", addr__postcode="44141")
    neighbor = giant_eagle(41, 41.31, -81.64, "Brecksville", "1")
    records = records_from(download(Walgreens=[walgreens], Giant_Eagle=[neighbor]),
                           [CHAIN["Walgreens"], CHAIN["Giant Eagle"]], ImportReport())
    assert records[0].address == "8966 Brecksville Road, Brecksville, OH 44141"
    # No neighbor in town, but another store's address says 441xx ZIP codes are in Ohio.
    elsewhere = giant_eagle(42, 41.50, -81.90, "Lakewood", "2")
    records = records_from(download(Walgreens=[walgreens], Giant_Eagle=[elsewhere]),
                           [CHAIN["Walgreens"], CHAIN["Giant Eagle"]], ImportReport())
    assert records[0].address == "8966 Brecksville Road, Brecksville, OH 44141"


def test_shouted_chain_names_read_like_the_chain():
    aldi = osm(50, 41, -81, shop="supermarket", name="ALDI", addr__city="Parma", addr__state="OH")
    assert to_record(CHAIN["Aldi"], aldi)[0].name == "Aldi Parma"


def test_a_street_without_a_town_gets_the_nearest_town():
    store = osm(60, 41.32, -81.67, shop="supermarket", name="Marc's",
                addr__housenumber="550", addr__street="West Aurora Road")
    stub = osm(61, 41.3201, -81.60, shop="supermarket", name="Marc's", addr__housenumber="4628B")
    records = records_from(download(Marc_s=[store, stub], Giant_Eagle=[
        giant_eagle(10, 41.32, -81.66, "Broadview Heights", "6337"),
    ]), [CHAIN["Marc's"], CHAIN["Giant Eagle"]], ImportReport())
    addresses = sorted(r.address for r in records if r.chain.name == "Marc's")
    assert addresses == ["550 West Aurora Road, near Broadview Heights, OH", "Near Broadview Heights, OH"]


@pytest.mark.parametrize("state", ["Illinois", "il", "IL"])
def test_states_are_written_as_codes(state):
    store = osm(70, 42.1, -88.4, shop="supermarket", addr__housenumber="10090", addr__street="Highway 47",
                addr__city="Huntley", addr__state=state, addr__postcode="60142")
    assert to_record(CHAIN["Jewel-Osco"], store)[0].address == "10090 Highway 47, Huntley, IL 60142"


def test_requests_are_guarded(db_client):
    assert db_client.head("/health").status_code == 200
    too_big = db_client.post("/lists/parse", content=b"x", headers={"content-length": str(9 * 1024 * 1024),
                                                                    "content-type": "application/json"})
    assert too_big.status_code == 413


def test_each_network_can_only_set_up_so_many_new_stores_a_day(engine, db_client, monkeypatch):
    from backend.app.config import get_settings

    monkeypatch.setattr(get_settings(), "aisle_new_store_maps_per_ip_per_day", 2)
    with Session(engine) as session:
        seed_all(session)
        import_download(session, download(Walmart=[walmart(2), walmart(3, lat=41.5), walmart(4, lat=41.7)]))
        ids = sorted(session.scalars(select(Store.id).where(Store.external_place_id.is_not(None))))
    one = {"X-Forwarded-For": "198.51.100.1"}
    assert [db_client.get(f"/stores/{i}/layout", headers=one).status_code for i in ids] == [200, 200, 429]
    # Stores already set up still open, and another network has its own allowance.
    assert db_client.get(f"/stores/{ids[0]}/layout", headers=one).status_code == 200
    assert db_client.get(f"/stores/{ids[2]}/layout", headers={"X-Forwarded-For": "198.51.100.2"}).status_code == 200


def test_the_client_ip_is_the_one_herokus_router_saw():
    from starlette.requests import Request

    from backend.app.limits import client_ip

    def request(forwarded):
        return Request({"type": "http", "headers": [(b"x-forwarded-for", forwarded.encode())], "client": ("10.1.1.1", 1)})

    assert client_ip(request("1.2.3.4, 203.0.113.7")) == "203.0.113.7"  # The first was made up by the client.
    assert client_ip(request("203.0.113.7")) == "203.0.113.7"


def test_cleanup_deletes_data_past_its_retention(engine):
    from datetime import datetime, timedelta, timezone

    from backend.app.cleanup import clean_up
    from backend.app.models import AnalyticsEvent, CodeRequest, EmailCode, UsageCounter

    now = datetime.now(timezone.utc)
    with Session(engine) as session:
        session.add_all([
            CodeRequest(channel="sms", target="+12155550100", created_at=now - timedelta(days=3)),
            CodeRequest(channel="sms", target="+12155550101", created_at=now),
            EmailCode(email="a@example.com", code_hash="x", expires_at=now, created_at=now - timedelta(days=2)),
            UsageCounter(subject="user:1", feature="photo_search", day=(now - timedelta(days=9)).date().isoformat()),
            UsageCounter(subject="user:1", feature="photo_search", day=now.date().isoformat()),
            UsageCounter(subject="user:1", feature="rl:search", day=(now - timedelta(days=3)).strftime("%Y%m%d%H")),
            UsageCounter(subject="user:1", feature="rl:search", day=now.strftime("%Y%m%d%H")),
            AnalyticsEvent(name="old", occurred_at=now, received_at=now - timedelta(days=200)),
        ])
        session.commit()
        assert clean_up(session, now) == {"code_requests": 1, "email_codes": 1, "usage_counters": 2,
                                          "analytics_events": 1, "search_events": 0}
        assert session.scalar(select(func.count()).select_from(UsageCounter)) == 2
        assert session.scalar(select(CodeRequest.target)) == "+12155550101"
