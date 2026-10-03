"""Resolve an item intent to a location in a store, in source priority order.

1. product_locations rows: "verified", then "retailer"     -> source "database", high
2. shopper consensus from location_observations           -> source "observations"
3. a "verified" store zone that holds the item's category  -> source "store_layout", medium
4. AI model (when configured and the strategy calls for it) -> source "model"
5. deterministic catalog + the store's template zones      -> source "fallback"

Database rows always beat the model: the model is not called when 1-3 match.
Aisle and section text only ever comes from rows in steps 1-3. Shopper-typed aisle
text needs several agreeing reports (see observations.py).

When several shoppers say an item is not in the zone we would suggest, the
answer's confidence drops to low.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.orm import Session

from .ai.catalog import layout_for_retailer
from .ai.intent import Intent
from .ai.providers import LocationModel
from .ai.reasoning import clean_neighbors, fallback_guess
from .config import get_settings
from .observations import ReportCounts, consensus, counts_by_zone, observations_for
from .models import (
    Category, ProductAlias, ProductConcept, ProductLocation, Store, StoreZone, zone_categories,
)
from .schemas import Availability, Confidence, LocationSource

# product_locations.source values, most trusted first.
LOCATION_SOURCE_PRIORITY = ("verified", "retailer")


@dataclass
class Resolution:
    concept: ProductConcept | None
    category_slug: str | None
    category_name: str | None
    department: str | None
    neighbors: list[str] = field(default_factory=list)
    aisle: str | None = None
    section: str | None = None
    zone_id: int | None = None
    availability: Availability = "unknown"
    confidence: Confidence = "low"
    source: LocationSource = "fallback"
    reports: ReportCounts | None = None


def find_concept(db: Session, intent: Intent) -> ProductConcept | None:
    candidates = [intent.normalized]
    if intent.match is not None and intent.match.term not in candidates:
        candidates.append(intent.match.term)
    rows = {
        alias.alias: alias.concept
        for alias in db.scalars(select(ProductAlias).where(ProductAlias.alias.in_(candidates)))
    }
    return next((rows[c] for c in candidates if c in rows), None)


def find_category(db: Session, intent: Intent, concept: ProductConcept | None) -> Category | None:
    if concept is not None:
        return concept.category
    if intent.match is not None:
        return db.scalar(select(Category).where(Category.slug == intent.match.category.slug))
    return None


def zone_for_category(db: Session, store: Store, category: Category | None) -> StoreZone | None:
    if category is None:
        return None
    zones = db.scalars(
        select(StoreZone)
        .join(zone_categories, zone_categories.c.zone_id == StoreZone.id)
        .where(StoreZone.store_id == store.id, zone_categories.c.category_id == category.id)
    ).all()
    # Verified zones beat template zones.
    return min(zones, key=lambda z: (z.source != "verified", z.sort_order), default=None)


def best_product_location(db: Session, store: Store, concept: ProductConcept | None) -> ProductLocation | None:
    if concept is None:
        return None
    rows = db.scalars(select(ProductLocation).where(
        ProductLocation.store_id == store.id,
        ProductLocation.concept_id == concept.id,
        ProductLocation.source.in_(LOCATION_SOURCE_PRIORITY),
    )).all()
    return min(rows, key=lambda r: LOCATION_SOURCE_PRIORITY.index(r.source), default=None)


def resolve(db: Session, intent: Intent, store: Store | None, model: LocationModel | None) -> Resolution:
    concept = find_concept(db, intent)
    observations = observations_for(db, store, concept, intent.normalized) if store else []
    result = _resolve(db, intent, store, model, concept, observations)
    if store is not None and result.zone_id is not None:
        result.reports = counts_by_zone(observations).get(result.zone_id, ReportCounts())
        doubted = result.reports.not_here >= 2 and result.reports.not_here > result.reports.found
        if doubted and result.source not in ("database", "observations"):
            result.confidence = "low"
    return result


def _resolve(
    db: Session, intent: Intent, store: Store | None, model: LocationModel | None,
    concept: ProductConcept | None, observations: list,
) -> Resolution:
    category = find_category(db, intent, concept)
    neighbors = clean_neighbors(list(category.neighbors), intent) if category else []

    def base(**overrides) -> Resolution:
        values = dict(
            concept=concept,
            category_slug=category.slug if category else None,
            category_name=category.name if category else None,
            department=None, neighbors=neighbors,
        )
        values.update(overrides)
        return Resolution(**values)

    zone = zone_for_category(db, store, category) if store else None

    if store is not None:
        location = best_product_location(db, store, concept)
        if location is not None:
            department = (
                location.zone.name if location.zone
                else zone.name if zone
                else category.name if category else None
            )
            return base(
                department=department,
                aisle=location.aisle_label or (location.zone.aisle_label if location.zone else None),
                section=location.section,
                zone_id=location.zone_id or (zone.id if zone else None),
                availability="likely", confidence="high", source="database",
            )
        agreed = consensus(observations)
        if agreed is not None:
            return base(
                department=agreed.zone.name, aisle=agreed.aisle or agreed.zone.aisle_label,
                zone_id=agreed.zone.id, availability="likely",
                confidence=agreed.confidence, source="observations",
            )
        if zone is not None and zone.source == "verified":
            return base(
                department=zone.name, aisle=zone.aisle_label, zone_id=zone.id,
                availability="likely", confidence="medium", source="store_layout",
            )

    layout = layout_for_retailer(store.retailer_name if store else None)
    guess = fallback_guess(intent, layout)
    use_model = model is not None and (
        get_settings().aisle_ai_strategy == "model_first" or intent.match is None
    )
    if use_model:
        guess = model.locate(intent, store.retailer_name if store else None, layout) or guess

    if guess.source == "model":
        model_zone = None
        if store is not None and guess.department:
            model_zone = db.scalar(select(StoreZone).where(
                StoreZone.store_id == store.id, StoreZone.name == guess.department
            ))
        return base(
            category_slug=guess.category.slug if guess.category else base().category_slug,
            category_name=guess.category.name if guess.category else base().category_name,
            department=guess.department, neighbors=guess.neighbors or neighbors,
            zone_id=model_zone.id if model_zone else None,
            availability=guess.availability, confidence=guess.confidence, source="model",
        )

    if zone is not None:
        # The store's own (template) zone for this category.
        return base(
            department=zone.name, zone_id=zone.id,
            availability="likely", confidence="medium", source="fallback",
        )
    if category is None and guess.category is not None:
        return base(
            category_slug=guess.category.slug, category_name=guess.category.name,
            department=guess.department, neighbors=guess.neighbors,
            availability=guess.availability, confidence=guess.confidence,
        )
    return base(
        department=guess.department,
        neighbors=neighbors or guess.neighbors,
        availability=guess.availability, confidence=guess.confidence,
    )
