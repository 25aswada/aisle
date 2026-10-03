"""Item search: parse the query, then resolve a structured location."""
from __future__ import annotations

from sqlalchemy.orm import Session

from .ai.catalog import layout_for_retailer
from .ai.intent import parse_intent
from .ai.providers import LocationModel
from .ai.reasoning import LocationGuess, fallback_guess
from .config import get_settings
from .models import Store
from .schemas import CategoryOut, LocationOut, SearchResponse


class StoreNotFound(Exception):
    pass


def generic_guess(intent, store: Store | None, model: LocationModel | None) -> LocationGuess:
    layout = layout_for_retailer(store.retailer_name if store else None)
    guess = fallback_guess(intent, layout)
    use_model = model is not None and (
        get_settings().aisle_ai_strategy == "model_first" or intent.match is None
    )
    if use_model:
        modeled = model.locate(intent, store.retailer_name if store else None, layout)
        if modeled is not None:
            guess = modeled
    return guess


def search(db: Session, query: str, store_id: int | None, model: LocationModel | None) -> SearchResponse:
    store = None
    if store_id is not None:
        store = db.get(Store, store_id)
        if store is None:
            raise StoreNotFound(store_id)
    intent = parse_intent(query)
    guess = generic_guess(intent, store, model)
    return SearchResponse(
        query=query,
        item=intent.item,
        modifiers=intent.modifiers,
        quantity=intent.quantity,
        store_id=store.id if store else None,
        category=CategoryOut(slug=guess.category.slug, name=guess.category.name) if guess.category else None,
        location=LocationOut(department=guess.department, neighbors=guess.neighbors),
        availability=guess.availability,
        confidence=guess.confidence,
        source=guess.source,
    )
