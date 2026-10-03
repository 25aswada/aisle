"""Item search: parse the query, then resolve a structured location."""
from __future__ import annotations

from sqlalchemy.orm import Session

from .ai.intent import parse_intent
from .ai.providers import LocationModel
from .models import Store
from .resolver import resolve
from .schemas import CategoryOut, ConceptOut, LocationOut, SearchResponse


class StoreNotFound(Exception):
    pass


def search(db: Session, query: str, store_id: int | None, model: LocationModel | None) -> SearchResponse:
    store = None
    if store_id is not None:
        store = db.get(Store, store_id)
        if store is None:
            raise StoreNotFound(store_id)
    intent = parse_intent(query)
    result = resolve(db, intent, store, model)
    return SearchResponse(
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
    )
