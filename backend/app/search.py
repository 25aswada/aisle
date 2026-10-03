"""Item search: parse the query, then resolve a structured location."""
from __future__ import annotations

from sqlalchemy.orm import Session

from .ai.intent import parse_intent
from .ai.providers import LocationModel
import logging

from .models import SearchEvent, Store
from .resolver import resolve
from .schemas import CategoryOut, ConceptOut, LocationOut, ReportCountsOut, SearchResponse

log = logging.getLogger(__name__)


class StoreNotFound(Exception):
    pass


def record_search_event(db: Session, query: str, intent, store: Store | None, result, device_id: str | None):
    """Best effort: a logging failure never fails the search."""
    event = SearchEvent(
        store_id=store.id if store else None, query=query, item_normalized=intent.normalized,
        concept_id=result.concept.id if result.concept else None, category_slug=result.category_slug,
        department=result.department, zone_id=result.zone_id, source=result.source,
        confidence=result.confidence, device_id=device_id,
    )
    try:
        db.add(event)
        db.commit()
        return event.id
    except Exception:
        db.rollback()
        log.warning("Couldn't record search event", exc_info=True)
        return None


def search(
    db: Session, query: str, store_id: int | None, model: LocationModel | None,
    device_id: str | None = None,
) -> SearchResponse:
    store = None
    if store_id is not None:
        store = db.get(Store, store_id)
        if store is None:
            raise StoreNotFound(store_id)
    intent = parse_intent(query)
    result = resolve(db, intent, store, model)
    search_id = record_search_event(db, query, intent, store, result, device_id)
    return SearchResponse(
        search_id=search_id,
        query=query,
        item=intent.item,
        modifiers=intent.modifiers,
        quantity=intent.quantity,
        store_id=store.id if store else None,
        concept=ConceptOut(id=result.concept.id, name=result.concept.name) if result.concept else None,
        category=(
            CategoryOut(slug=result.category_slug, name=result.category_name)
            if result.category_slug else None
        ),
        location=LocationOut(
            department=result.department, aisle=result.aisle, section=result.section,
            zone_id=result.zone_id, neighbors=result.neighbors,
        ),
        availability=result.availability,
        confidence=result.confidence,
        source=result.source,
        reports=(
            ReportCountsOut(found=result.reports.found, not_here=result.reports.not_here)
            if result.reports else None
        ),
    )
