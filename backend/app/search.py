"""Item search: parse the query, then resolve a structured location."""
from __future__ import annotations

from sqlalchemy.orm import Session

import logging

from .ai.explain import Explainer, ExplainFacts, explain_safely, position_words
from .ai.intent import parse_intent
from .ai.providers import LocationModel
from .models import SearchEvent, Store, StoreZone
from .resolver import resolve
from .schemas import CategoryOut, ConceptOut, LocationOut, ReportCountsOut, SearchResponse
from .store_zones import get_store

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


def explain_facts(db: Session, intent, store: Store | None, result) -> ExplainFacts:
    zone = db.get(StoreZone, result.zone_id) if result.zone_id else None
    # A category with no matching zone at a store that doesn't stock it isn't a place.
    department = None if result.availability == "unlikely" and zone is None else result.department
    return ExplainFacts(
        item=intent.item,
        retailer=store.retailer_name if store else None,
        store_name=store.name if store else None,
        department=department,
        aisle=result.aisle,
        section=result.section,
        category=result.category_name,
        neighbors=tuple(result.neighbors[:4]),
        confidence=result.confidence,
        availability=result.availability,
        source=result.source,
        modifiers=tuple(intent.modifiers),
        found_reports=result.reports.found if result.reports else 0,
        not_here_reports=result.reports.not_here if result.reports else 0,
        position=position_words(zone.x, zone.y) if zone else None,
        layout_is_template=zone is None or zone.source == "template",
    )


def search(
    db: Session, query: str, store_id: int | None, model: LocationModel | None,
    device_id: str | None = None, explainer: Explainer | None = None,
) -> SearchResponse:
    store = None
    if store_id is not None:
        store = get_store(db, store_id)
        if store is None:
            raise StoreNotFound(store_id)
    intent = parse_intent(query)
    result = resolve(db, intent, store, model)
    search_id = record_search_event(db, query, intent, store, result, device_id)
    facts = explain_facts(db, intent, store, result) if store else None
    db.commit()  # Hand the connection back while the AI writes (it can take seconds).
    explanation = explain_safely(explainer, facts) if facts else None
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
        explanation=explanation,
    )
