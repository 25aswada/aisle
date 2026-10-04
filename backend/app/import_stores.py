"""Import real US store locations for major chains from OpenStreetMap.

    python -m backend.app.import_stores                         # fetch every chain, then load
    python -m backend.app.import_stores --save stores.json      # fetch and keep the download
    python -m backend.app.import_stores --from-file stores.json # load a saved download
    python -m backend.app.import_stores --chain "Giant Eagle" --bbox 41.0,-82.0,41.6,-81.3

Stores come from the Overpass API, matched by each chain's Wikidata ID (OSM's
brand:wikidata tag), so a store is only imported if mappers tied it to the chain. OSM
data is © OpenStreetMap contributors under the ODbL; the app credits it where stores
are listed.

Re-running is safe: a store is matched to an existing one by its OSM ID, then by its
chain's store number, then by being the same chain within STORE_MATCH_METERS, and is
updated in place, so IDs (and anything shoppers reported there) are kept. Stores that
are no longer in OSM are listed, and deleted only with --prune.

Imported stores get no zones up front; their chain's layout template is copied the
first time each store is used (store_zones.ensure_zones).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timezone
from math import cos, floor, radians

from sqlalchemy import select
from sqlalchemy.orm import Session

from .database import get_engine
from .models import Retailer, Store

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
USER_AGENT = "AisleStoreImport/1.0 (+https://shopaisle.app)"
# Two OSM objects of the same chain this close together are one store (often a
# building outline plus a point for the same shop).
STORE_MATCH_METERS = 150
# A store OSM has no address for is described by the nearest town within this distance.
NEAR_TOWN_METERS = 15_000
# Hand-added stores (the demo stores) have rough coordinates, so they match an OSM store
# of their chain on the same street this far away.
HAND_ADDED_MATCH_METERS = 600
STATE_CODES = {
    "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR", "california": "CA",
    "colorado": "CO", "connecticut": "CT", "delaware": "DE", "district of columbia": "DC",
    "florida": "FL", "georgia": "GA", "hawaii": "HI", "idaho": "ID", "illinois": "IL",
    "indiana": "IN", "iowa": "IA", "kansas": "KS", "kentucky": "KY", "louisiana": "LA",
    "maine": "ME", "maryland": "MD", "massachusetts": "MA", "michigan": "MI", "minnesota": "MN",
    "mississippi": "MS", "missouri": "MO", "montana": "MT", "nebraska": "NE", "nevada": "NV",
    "new hampshire": "NH", "new jersey": "NJ", "new mexico": "NM", "new york": "NY",
    "north carolina": "NC", "north dakota": "ND", "ohio": "OH", "oklahoma": "OK", "oregon": "OR",
    "pennsylvania": "PA", "rhode island": "RI", "south carolina": "SC", "south dakota": "SD",
    "tennessee": "TN", "texas": "TX", "utah": "UT", "vermont": "VT", "virginia": "VA",
    "washington": "WA", "west virginia": "WV", "wisconsin": "WI", "wyoming": "WY",
    "puerto rico": "PR",
}
_STREET_WORDS = {"n", "s", "e", "w", "north", "south", "east", "west", "the"}


@dataclass(frozen=True)
class Chain:
    name: str          # Retailer name in Aisle; chooses the store map (ai.catalog).
    domain: str        # For the retailer logo.
    wikidata: tuple[str, ...]
    layout: str        # The ai.catalog layout this chain's stores get; checked by tests.
    pharmacy: bool = False  # Pharmacies are often tagged amenity=pharmacy, not as a shop.


CHAINS: tuple[Chain, ...] = (
    # Chains with researched store maps (ai.chain_layouts).
    Chain("Walmart", "walmart.com", ("Q483551",), "walmart"),
    Chain("Target", "target.com", ("Q1046951",), "target"),
    Chain("Costco", "costco.com", ("Q715583",), "costco"),
    Chain("Sam's Club", "samsclub.com", ("Q1972120",), "sams_club"),
    Chain("Kroger", "kroger.com", ("Q153417",), "kroger"),
    Chain("Aldi", "aldi.us", ("Q41171672",), "aldi"),
    Chain("Trader Joe's", "traderjoes.com", ("Q688825",), "trader_joes"),
    Chain("Whole Foods Market", "wholefoodsmarket.com", ("Q1809448",), "whole_foods"),
    Chain("CVS", "cvs.com", ("Q2078880",), "cvs", pharmacy=True),
    Chain("Walgreens", "walgreens.com", ("Q1591889",), "walgreens", pharmacy=True),
    Chain("Home Depot", "homedepot.com", ("Q864407",), "home_depot"),
    Chain("Lowe's", "lowes.com", ("Q1373493",), "lowes"),
    # Chains that use their store format's generic map.
    Chain("Walmart Neighborhood Market", "walmart.com", ("Q7963529",), "grocery"),
    Chain("BJ's Wholesale Club", "bjs.com", ("Q4835754",), "warehouse_club"),
    Chain("Meijer", "meijer.com", ("Q1917753",), "supercenter"),
    Chain("Fred Meyer", "fredmeyer.com", ("Q5495932",), "supercenter"),
    Chain("Menards", "menards.com", ("Q1639897",), "home_improvement"),
    Chain("Ace Hardware", "acehardware.com", ("Q4672981",), "home_improvement"),
    Chain("Giant Eagle", "gianteagle.com", ("Q1522721",), "grocery"),
    Chain("Marc's", "marcs.com", ("Q17080259",), "grocery"),
    Chain("Publix", "publix.com", ("Q672170",), "grocery"),
    Chain("H-E-B", "heb.com", ("Q830621",), "grocery"),
    Chain("Wegmans", "wegmans.com", ("Q11288478",), "grocery"),
    Chain("Safeway", "safeway.com", ("Q1508234",), "grocery"),
    Chain("Albertsons", "albertsons.com", ("Q2831861",), "grocery"),
    Chain("Vons", "vons.com", ("Q7941609",), "grocery"),
    Chain("Pavilions", "pavilions.com", ("Q7155886",), "grocery"),
    Chain("Jewel-Osco", "jewelosco.com", ("Q3178470",), "grocery"),
    Chain("Acme", "acmemarkets.com", ("Q341975",), "grocery"),
    Chain("Shaw's", "shaws.com", ("Q578387",), "grocery"),
    Chain("Tom Thumb", "tomthumb.com", ("Q7817826",), "grocery"),
    Chain("Ralphs", "ralphs.com", ("Q3929820",), "grocery"),
    Chain("King Soopers", "kingsoopers.com", ("Q6412065",), "grocery"),
    Chain("Smith's", "smithsfoodanddrug.com", ("Q7544856",), "grocery"),
    Chain("Fry's Food and Drug", "frysfood.com", ("Q5506547",), "grocery"),
    Chain("Dillons", "dillons.com", ("Q5276954",), "grocery"),
    Chain("QFC", "qfc.com", ("Q7265425",), "grocery"),
    Chain("Mariano's", "marianos.com", ("Q55622168",), "grocery"),
    Chain("Pick 'n Save", "picknsave.com", ("Q7371288",), "grocery"),
    Chain("Food 4 Less", "food4less.com", ("Q5465282",), "grocery"),
    Chain("Harris Teeter", "harristeeter.com", ("Q5665067",), "grocery"),
    Chain("Food Lion", "foodlion.com", ("Q1435950",), "grocery"),
    Chain("Stop & Shop", "stopandshop.com", ("Q3658429",), "grocery"),
    Chain("Giant Food", "giantfood.com", ("Q5558336",), "grocery"),
    Chain("The Giant Company", "giantfoodstores.com", ("Q5558332",), "grocery"),
    Chain("Hannaford", "hannaford.com", ("Q5648760",), "grocery"),
    Chain("ShopRite", "shoprite.com", ("Q7501097",), "grocery"),
    Chain("Weis Markets", "weismarkets.com", ("Q7980370",), "grocery"),
    Chain("Tops", "topsmarkets.com", ("Q7825137",), "grocery"),
    Chain("Hy-Vee", "hy-vee.com", ("Q1639719",), "grocery"),
    Chain("Schnucks", "schnucks.com", ("Q7431920",), "grocery"),
    Chain("Dierbergs", "dierbergs.com", ("Q5274978",), "grocery"),
    Chain("Cub Foods", "cub.com", ("Q5191916",), "grocery"),
    Chain("Fareway", "fareway.com", ("Q5434998",), "grocery"),
    Chain("Winn-Dixie", "winndixie.com", ("Q1264366",), "grocery"),
    Chain("Ingles", "ingles-markets.com", ("Q6032595",), "grocery"),
    Chain("Lowes Foods", "lowesfoods.com", ("Q6693991",), "grocery"),
    Chain("Brookshire's", "brookshires.com", ("Q4975085",), "grocery"),
    Chain("WinCo Foods", "wincofoods.com", ("Q8023592",), "grocery"),
    Chain("Stater Bros.", "staterbros.com", ("Q7604016",), "grocery"),
    Chain("Raley's", "raleys.com", ("Q7286970",), "grocery"),
    Chain("Save Mart", "savemart.com", ("Q7428009",), "grocery"),
    Chain("Smart & Final", "smartandfinal.com", ("Q7543916",), "grocery"),
    Chain("Sprouts Farmers Market", "sprouts.com", ("Q7581369",), "grocery"),
    Chain("The Fresh Market", "thefreshmarket.com", ("Q7735265",), "grocery"),
    Chain("Fresh Thyme Market", "freshthyme.com", ("Q64132791",), "grocery"),
    Chain("Natural Grocers", "naturalgrocers.com", ("Q17146520",), "grocery"),
    Chain("Lidl", "lidl.com", ("Q151954",), "grocery"),
    Chain("Save A Lot", "savealot.com", ("Q7427972",), "grocery"),
    Chain("Grocery Outlet", "groceryoutlet.com", ("Q5609934",), "grocery"),
    Chain("H Mart", "hmart.com", ("Q5636306",), "grocery"),
)

# OSM shop types that are a store itself (not its gas station, pharmacy counter, tire
# center or optician, which carry the same brand tag).
STORE_SHOPS = {
    "supermarket", "department_store", "wholesale", "doityourself", "hardware",
    "general", "variety_store", "chemist",
}


@dataclass
class StoreRecord:
    chain: Chain
    osm_id: str
    name: str
    address: str
    latitude: float
    longitude: float
    store_number: str | None
    # How complete the address is; the better of two duplicates is kept.
    detail: int = 0
    housenumber: str = ""
    street: str = ""
    city: str = ""
    state: str = ""
    postcode: str = ""

    def could_be(self, other: "StoreRecord") -> bool:
        """Close by and nothing says they're different stores."""
        if self.store_number and other.store_number and self.store_number != other.store_number:
            return False
        if self.housenumber and other.housenumber and self.housenumber != other.housenumber:
            return False
        return meters_between(self.latitude, self.longitude, other.latitude, other.longitude) <= STORE_MATCH_METERS


@dataclass
class ImportReport:
    created: int = 0
    updated: int = 0
    unchanged: int = 0
    duplicates: int = 0
    skipped: dict[str, int] = field(default_factory=dict)
    stale: list[str] = field(default_factory=list)  # "id name, address"
    pruned: int = 0

    def skip(self, reason: str) -> None:
        self.skipped[reason] = self.skipped.get(reason, 0) + 1


# --- Fetching ---------------------------------------------------------------------

# Overpass spends its time scanning the country for brand tags, about the same for one
# chain as for many, so chains are fetched a batch at a time.
CHAINS_PER_QUERY = 12


def overpass_query(chains: Sequence[Chain], bbox: Sequence[float] | None) -> str:
    ids = "|".join(qid for chain in chains for qid in chain.wikidata)
    if bbox:
        south, west, north, east = bbox
        return (f'[out:json][timeout:600];nwr["brand:wikidata"~"^({ids})$"]'
                f"({south},{west},{north},{east});out center tags;")
    return ('[out:json][timeout:600];area["ISO3166-1"="US"][admin_level=2]->.us;'
            f'nwr["brand:wikidata"~"^({ids})$"](area.us);out center tags;')


def fetch_elements(chains: Sequence[Chain], bbox: Sequence[float] | None, url: str = OVERPASS_URL,
                   attempts: int = 6) -> list[dict]:
    body = urllib.parse.urlencode({"data": overpass_query(chains, bbox)}).encode()
    request = urllib.request.Request(url, data=body, headers={"User-Agent": USER_AGENT})
    names = ", ".join(chain.name for chain in chains)
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=700) as response:
                data = json.load(response)
            remark = data.get("remark") or ""
            if "timed out" in remark or "error" in remark.lower():
                raise RuntimeError(remark)
            return data["elements"]
        except (urllib.error.URLError, TimeoutError, RuntimeError, json.JSONDecodeError) as error:
            if attempt == attempts - 1:
                raise RuntimeError(f"Overpass failed for {names}: {error}") from error
            wait = 20 * (attempt + 1)  # Overpass asks busy clients to back off.
            print(f"  {error}; retrying in {wait}s", file=sys.stderr)
            time.sleep(wait)
    return []


def fetch_all(chains: Sequence[Chain], bbox: Sequence[float] | None, url: str = OVERPASS_URL,
              save: str | None = None) -> dict:
    """Download every chain. With `save`, the file is rewritten after each batch, and
    chains already in it from an earlier run of the same area are not fetched again."""
    download = {
        "source": "OpenStreetMap via the Overpass API. © OpenStreetMap contributors, ODbL.",
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "bbox": list(bbox) if bbox else None,
        "chains": {},
    }
    if save and os.path.exists(save):
        with open(save) as handle:
            earlier = json.load(handle)
        if earlier.get("bbox") == download["bbox"]:
            download = earlier
            print(f"Resuming {save}: {len(earlier['chains'])} chains already fetched", file=sys.stderr)
    missing = [chain for chain in chains if chain.name not in download["chains"]]
    by_wikidata = {qid: chain for chain in missing for qid in chain.wikidata}
    for start in range(0, len(missing), CHAINS_PER_QUERY):
        batch = missing[start:start + CHAINS_PER_QUERY]
        found: dict[str, list] = {chain.name: [] for chain in batch}
        for element in fetch_elements(batch, bbox, url):
            chain = by_wikidata.get((element.get("tags") or {}).get("brand:wikidata"))
            if chain is not None:
                found[chain.name].append(element)
        download["chains"].update(found)
        for chain in batch:
            print(f"Fetched {len(found[chain.name]):>5} OSM objects for {chain.name}", file=sys.stderr)
        if save:
            with open(save, "w") as handle:
                json.dump(download, handle)
    return download


# --- Turning OSM objects into stores -----------------------------------------------

def _tag(tags: dict, key: str) -> str:
    return " ".join((tags.get(key) or "").split())


def street_address(tags: dict) -> str:
    """'8160 Macedonia Commons Boulevard', or '' (a street name alone isn't an address)."""
    if not (_tag(tags, "addr:housenumber") and _tag(tags, "addr:street")):
        return ""
    return f'{_tag(tags, "addr:housenumber")} {_tag(tags, "addr:street")}'


def format_address(street: str, city: str, state: str, postcode: str) -> tuple[str, int]:
    """'8160 Macedonia Commons Boulevard, Macedonia, OH 44056', and how many parts it has."""
    parts = [p for p in (street, city, " ".join(p for p in (state, postcode) if p)) if p]
    return ", ".join(parts), len(parts)


def store_name(chain: Chain, tags: dict) -> str:
    """The chain's name for this kind of store plus where it is: 'Walmart Supercenter
    Macedonia', 'Giant Eagle Broadview Heights'."""
    osm_name = _tag(tags, "name")
    # Keep the OSM name when it's the chain's own ("Walmart Supercenter", "CVS Pharmacy",
    # "Kroger Marketplace"), not something else or a store number.
    first_word = chain.name.split()[0].lower().rstrip("'s")
    base = osm_name if osm_name and first_word in osm_name.lower() and "#" not in osm_name else chain.name
    if base.lower() == chain.name.lower():
        base = chain.name  # "ALDI" -> "Aldi", so one chain reads the same everywhere.
    place = _tag(tags, "branch") or _tag(tags, "addr:city")
    if place and place.lower() not in base.lower():
        return f"{base} {place}"[:200]
    return base[:200]


def to_record(chain: Chain, element: dict) -> tuple[StoreRecord | None, str | None]:
    """A store, or why the OSM object isn't one."""
    tags = element.get("tags") or {}
    if any(tags.get(k) == "yes" for k in ("disused", "abandoned")) or tags.get("opening_hours") == "closed":
        return None, "closed"
    is_store = tags.get("shop") in STORE_SHOPS or (chain.pharmacy and tags.get("amenity") == "pharmacy")
    if not is_store:
        return None, "not the store itself (fuel, pharmacy counter, auto care…)"
    point = element.get("center") or element
    latitude, longitude = point.get("lat"), point.get("lon")
    if latitude is None or longitude is None:
        return None, "no coordinates"
    street, city, postcode = street_address(tags), _tag(tags, "addr:city"), _tag(tags, "addr:postcode")
    state = _tag(tags, "addr:state")
    state = STATE_CODES.get(state.lower(), state.upper() if len(state) == 2 else state)
    address, detail = format_address(street, city, state, postcode)  # May be empty; see records_from.
    ref = _tag(tags, "ref") or None
    return StoreRecord(
        chain=chain, osm_id=f"osm:{element['type']}/{element['id']}", name=store_name(chain, tags),
        address=address[:500], latitude=float(latitude), longitude=float(longitude),
        store_number=ref if ref and len(ref) <= 50 else None, detail=detail,
        housenumber=_tag(tags, "addr:housenumber"), street=street, city=city, state=state, postcode=postcode,
    ), None


def meters_between(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Flat-earth distance; accurate at the few hundred meters it's used for."""
    dy = radians(lat2 - lat1)
    dx = radians(lon2 - lon1) * cos(radians((lat1 + lat2) / 2))
    return 6_371_009 * (dx * dx + dy * dy) ** 0.5


class Grid:
    """Finds things within about `meters` of a point."""

    def __init__(self, meters: float = STORE_MATCH_METERS):
        self.cell = meters / 111_000
        self.cells: dict[tuple, list] = {}

    def _cell(self, latitude, longitude, key):
        return key, floor(latitude / self.cell), floor(longitude / self.cell)

    def add(self, key, latitude, longitude, item) -> None:
        self.cells.setdefault(self._cell(latitude, longitude, key), []).append(item)

    def remove(self, key, latitude, longitude, item) -> None:
        self.cells.get(self._cell(latitude, longitude, key), []).remove(item)

    def near(self, key, latitude, longitude):
        _, row, col = self._cell(latitude, longitude, key)
        for dr in (-1, 0, 1):
            # Longitude cells are narrower than CELL meters away from the equator.
            span = max(1, round(1 / max(cos(radians(latitude)), 0.1)))
            for dc in range(-span, span + 1):
                yield from self.cells.get((key, row + dr, col + dc), [])


def records_from(download: dict, chains: Iterable[Chain], report: ImportReport) -> list[StoreRecord]:
    """Stores from a download, one per real store. OSM often has a building outline and a
    point for the same shop, so same-chain objects that could be one store merge. A store
    OSM has no address for is placed by the nearest town ("Near Parma, OH") that another
    imported store's address names, or skipped if there's none close."""
    kept: list[StoreRecord] = []
    grid = Grid()
    for chain in chains:
        for element in download["chains"].get(chain.name, []):
            record, reason = to_record(chain, element)
            if record is None:
                report.skip(reason)
                continue
            twin = next((other for other in grid.near(chain.name, record.latitude, record.longitude)
                         if other.could_be(record)), None)
            if twin is None:
                kept.append(record)
                grid.add(chain.name, record.latitude, record.longitude, record)
                continue
            report.duplicates += 1
            if (record.detail, record.store_number is not None) > (twin.detail, twin.store_number is not None):
                record.store_number = record.store_number or twin.store_number
                kept[kept.index(twin)] = record
                grid.remove(chain.name, twin.latitude, twin.longitude, twin)
                grid.add(chain.name, record.latitude, record.longitude, record)
            else:
                twin.store_number = twin.store_number or record.store_number

    towns = Grid(NEAR_TOWN_METERS)
    for record in kept:
        if record.city and record.state:
            towns.add(None, record.latitude, record.longitude, record)
    # OSM often leaves out the state. A US ZIP code's first three digits are in one state,
    # so other stores' addresses say which; failing that, a neighbor in the same town does.
    zip_states: dict[str, Counter] = {}
    for record in kept:
        if record.state and record.postcode[:3].isdigit():
            zip_states.setdefault(record.postcode[:3], Counter())[record.state.upper()] += 1
    placed = []
    for record in kept:
        distance = lambda other: meters_between(other.latitude, other.longitude, record.latitude, record.longitude)
        if (record.city or record.postcode) and not record.state:
            if record.postcode[:3] in zip_states:
                record.state = zip_states[record.postcode[:3]].most_common(1)[0][0]
            elif record.city:
                twin_town = min((other for other in towns.near(None, record.latitude, record.longitude)
                                 if other.city.lower() == record.city.lower() and distance(other) <= NEAR_TOWN_METERS),
                                key=distance, default=None)
                record.state = twin_town.state if twin_town else ""
            record.address = format_address(record.street, record.city, record.state, record.postcode)[0][:500]
        if not (record.city and record.state):
            # Say which town it's near, after the street if OSM has one.
            town = min((other for other in towns.near(None, record.latitude, record.longitude)
                        if distance(other) <= NEAR_TOWN_METERS), key=distance, default=None)
            if town is not None:
                near = f"near {town.city}, {town.state}"
                record.address = f"{record.street}, {near}" if record.street else near[0].upper() + near[1:]
            elif not record.street:
                report.skip("no address, and no town nearby")
                continue
        placed.append(record)
    return placed


# --- Loading -----------------------------------------------------------------------

def street_key(address: str) -> str:
    """The street's main word: '1675 S Christopher Columbus Blvd, …' -> 'christopher'."""
    words = address.split(",")[0].lower().replace(".", "").split()
    words = [w for w in words if not any(ch.isdigit() for ch in w) and w not in _STREET_WORDS]
    return words[0] if words else ""


def _retailer(session: Session, chain: Chain) -> Retailer:
    retailer = session.scalar(select(Retailer).where(Retailer.name == chain.name))
    if retailer is None:
        retailer = Retailer(name=chain.name, domain=chain.domain)
        session.add(retailer)
        session.flush()
    elif retailer.domain is None:  # Backfill only; never overwrite an edited domain.
        retailer.domain = chain.domain
    return retailer


def _inside(store: Store, bbox: Sequence[float] | None) -> bool:
    if not bbox:
        return True
    south, west, north, east = bbox
    return south <= store.latitude <= north and west <= store.longitude <= east


def load(session: Session, records: list[StoreRecord], chains: Sequence[Chain],
         bbox: Sequence[float] | None = None, prune: bool = False, commit: bool = True) -> ImportReport:
    """Create or update a store for each record; see the module docstring for matching."""
    report = ImportReport()
    retailers = {chain.name: _retailer(session, chain) for chain in chains}
    existing = list(session.scalars(
        select(Store).where(Store.retailer_id.in_([r.id for r in retailers.values()]))
    ))
    by_osm_id = {s.external_place_id: s for s in existing if s.external_place_id}
    by_number = {(s.retailer_id, s.store_number): s for s in existing if s.store_number}
    grid = Grid()
    for store in existing:
        grid.add(store.retailer_id, store.latitude, store.longitude, store)

    # Exact OSM matches first, so a nearby store can't take another store's match.
    matches: dict[int, Store] = {}
    for index, record in enumerate(records):
        if (store := by_osm_id.get(record.osm_id)) is not None:
            matches[index] = store
    claimed = {store.id for store in matches.values()}
    for index, record in enumerate(records):
        if index in matches:
            continue
        retailer_id = retailers[record.chain.name].id
        store = by_number.get((retailer_id, record.store_number)) if record.store_number else None
        if store is None or store.id in claimed:
            distance = lambda s: meters_between(s.latitude, s.longitude, record.latitude, record.longitude)
            store = min((s for s in grid.near(retailer_id, record.latitude, record.longitude)
                         if s.id not in claimed and distance(s) <= STORE_MATCH_METERS), key=distance, default=None)
        if store is not None:
            matches[index] = store
            claimed.add(store.id)
    for store in existing:
        if store.external_place_id is None and store.id not in claimed and street_key(store.address):
            distance = lambda r: meters_between(r.latitude, r.longitude, store.latitude, store.longitude)
            index = min((i for i, r in enumerate(records)
                         if i not in matches and retailers[r.chain.name].id == store.retailer_id
                         and abs(r.latitude - store.latitude) < 0.01 and distance(r) <= HAND_ADDED_MATCH_METERS
                         and street_key(r.address) == street_key(store.address)),
                        key=lambda i: distance(records[i]), default=None)
            if index is not None:
                matches[index] = store
                claimed.add(store.id)

    for index, record in enumerate(records):
        values = dict(
            retailer_id=retailers[record.chain.name].id, name=record.name, address=record.address,
            latitude=record.latitude, longitude=record.longitude,
            external_place_id=record.osm_id, store_number=record.store_number,
        )
        store = matches.get(index)
        if store is None:
            session.add(Store(**values))
            report.created += 1
        elif all(getattr(store, key) == value for key, value in values.items()):
            report.unchanged += 1
        else:
            for key, value in values.items():
                setattr(store, key, value)
            report.updated += 1

    stale = [
        s for s in existing
        if (s.external_place_id or "").startswith("osm:") and s.id not in claimed and _inside(s, bbox)
    ]
    report.stale = [f"{s.id} {s.name}, {s.address}" for s in stale]
    if prune:
        for store in stale:
            session.delete(store)
        report.pruned = len(stale)
    if commit:
        session.commit()
    else:
        session.flush()
    return report


# --- Command line ------------------------------------------------------------------

def _bbox(text: str) -> tuple[float, float, float, float]:
    south, west, north, east = (float(v) for v in text.split(","))
    if not (-90 <= south < north <= 90 and -180 <= west < east <= 180):
        raise argparse.ArgumentTypeError("bbox is south,west,north,east")
    return south, west, north, east


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--chain", action="append", help="only this chain (repeatable)")
    parser.add_argument("--bbox", type=_bbox, help="only this area: south,west,north,east")
    parser.add_argument("--save", help="write the OSM download to this file (resumes if it exists)")
    parser.add_argument("--from-file", help="load a saved download instead of fetching")
    parser.add_argument("--fetch-only", action="store_true", help="download (with --save) without loading")
    parser.add_argument("--dry-run", action="store_true", help="report what would change without saving")
    parser.add_argument("--prune", action="store_true", help="delete imported stores no longer in OSM")
    parser.add_argument("--overpass-url", default=OVERPASS_URL)
    args = parser.parse_args(argv)

    chains = list(CHAINS)
    if args.chain:
        names = {c.name.lower(): c for c in CHAINS}
        unknown = [n for n in args.chain if n.lower() not in names]
        if unknown:
            parser.error(f"unknown chain {unknown[0]!r}; known: {', '.join(c.name for c in CHAINS)}")
        chains = [names[n.lower()] for n in args.chain]

    if args.from_file:
        with open(args.from_file) as handle:
            download = json.load(handle)
        chains = [c for c in chains if c.name in download["chains"]]
        bbox = args.bbox or download.get("bbox")
    else:
        bbox = args.bbox
        download = fetch_all(chains, bbox, args.overpass_url, save=args.save)
        if args.save:
            print(f"Saved the download to {args.save}", file=sys.stderr)
    if args.fetch_only:
        return

    skipped = ImportReport()
    records = records_from(download, chains, skipped)
    with Session(get_engine()) as session:
        report = load(session, records, chains, bbox, prune=args.prune, commit=not args.dry_run)
        if args.dry_run:
            session.rollback()
        else:
            print("Saved to the database.", file=sys.stderr)
    report.duplicates, report.skipped = skipped.duplicates, skipped.skipped

    print(f"{len(records)} stores from OSM ({report.duplicates} duplicate objects merged).")
    print(f"Created {report.created}, updated {report.updated}, unchanged {report.unchanged}.")
    for reason, count in sorted(report.skipped.items(), key=lambda item: -item[1]):
        print(f"Skipped {count}: {reason}")
    if report.stale:
        verb = "Deleted" if report.pruned and not args.dry_run else "Not in OSM any more (rerun with --prune to delete)"
        print(f"{verb}: {len(report.stale)}")
        for line in report.stale[:20]:
            print(f"  {line}")


if __name__ == "__main__":
    main()
