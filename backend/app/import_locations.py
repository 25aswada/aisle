"""Import real product locations from CSV.

    python -m backend.app.import_locations locations.csv

Columns: store_id, item, source, department, aisle, section
- source is "verified" (checked in the store) or "retailer" (retailer-provided data).
- item is matched to a product concept by its normalized name. Unknown items are
  created under the catalog category the parser matches; rows the parser can't
  classify are skipped.
- department names a store zone; a missing zone is created as "verified".
- aisle and section are stored exactly as given. This is the only way aisle text
  enters the database.
"""
from __future__ import annotations

import csv
import sys
from collections.abc import Iterable
from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.orm import Session

from .ai.intent import normalize, parse_intent
from .database import get_engine
from .models import Category, ProductAlias, ProductConcept, ProductLocation, Store, StoreZone, utcnow
from .resolver import LOCATION_SOURCE_PRIORITY


@dataclass
class ImportReport:
    imported: int = 0
    skipped: list[str] = field(default_factory=list)


def _clean(value: str | None) -> str | None:
    value = (value or "").strip()
    return value or None


def _concept_for(db: Session, item: str) -> ProductConcept | None:
    alias = db.scalar(select(ProductAlias).where(ProductAlias.alias == normalize(item)))
    if alias is not None:
        return alias.concept
    intent = parse_intent(item)
    if intent.match is None:
        return None
    category = db.scalar(select(Category).where(Category.slug == intent.match.category.slug))
    if category is None:
        return None
    concept = ProductConcept(name=item.strip().lower(), category=category,
                             aliases=[ProductAlias(alias=normalize(item))])
    db.add(concept)
    db.flush()
    return concept


def import_rows(db: Session, rows: Iterable[dict]) -> ImportReport:
    report = ImportReport()
    for line, row in enumerate(rows, start=2):
        source = _clean(row.get("source"))
        item = _clean(row.get("item"))
        try:
            store = db.get(Store, int(row.get("store_id") or 0))
        except ValueError:
            store = None
        if store is None or not item or source not in LOCATION_SOURCE_PRIORITY:
            report.skipped.append(f"line {line}: needs a valid store_id, item, and source")
            continue
        concept = _concept_for(db, item)
        if concept is None:
            report.skipped.append(f"line {line}: can't classify item {item!r}")
            continue
        zone = None
        department = _clean(row.get("department"))
        if department:
            zone = db.scalar(select(StoreZone).where(StoreZone.store_id == store.id, StoreZone.name == department))
            if zone is None:
                zone = StoreZone(store_id=store.id, name=department, source="verified", sort_order=999)
                db.add(zone)
                db.flush()
        location = db.scalar(select(ProductLocation).where(
            ProductLocation.store_id == store.id,
            ProductLocation.concept_id == concept.id,
            ProductLocation.source == source,
        )) or ProductLocation(store_id=store.id, concept_id=concept.id, source=source)
        location.zone_id = zone.id if zone else None
        location.aisle_label = _clean(row.get("aisle"))
        location.section = _clean(row.get("section"))
        location.updated_at = utcnow()
        db.add(location)
        report.imported += 1
    db.commit()
    return report


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], newline="") as handle, Session(get_engine()) as session:
        result = import_rows(session, csv.DictReader(handle))
    print(f"Imported {result.imported} locations.")
    for problem in result.skipped:
        print("Skipped", problem)
