from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..ai.intent import parse_intent
from ..config import get_settings
from ..database import get_db
from ..limits import rate_limit
from ..models import LocationObservation, SearchEvent, StoreZone
from ..observations import counts_by_zone, observations_for
from ..resolver import find_concept
from ..schemas import (
    FeedbackRequest, FeedbackResponse, LayoutPoint, LayoutZoneOut, ReportCountsOut, StoreLayoutOut, StoreZoneOut,
)
from ..store_zones import get_store
from .auth import CallerDep

router = APIRouter()
Database = Annotated[Session, Depends(get_db)]


@router.get("/stores/{store_id}/zones", response_model=list[StoreZoneOut])
def store_zones(store_id: int, db: Database, response: Response):
    if get_store(db, store_id) is None:
        raise HTTPException(status_code=404, detail="Store not found")
    # Zones change rarely; let the app's URL cache reuse them for a few minutes.
    response.headers["Cache-Control"] = "public, max-age=300"
    return db.scalars(
        select(StoreZone).where(StoreZone.store_id == store_id).order_by(StoreZone.sort_order, StoreZone.id)
    ).all()


@router.get("/stores/{store_id}/layout", response_model=StoreLayoutOut)
def store_layout(store_id: int, db: Database, response: Response):
    """Approximate floor plan for drawing a schematic map: zone positions plus the
    entrance and checkout. Template positions are per store format, not real plans."""
    store = get_store(db, store_id)
    if store is None:
        raise HTTPException(status_code=404, detail="Store not found")
    response.headers["Cache-Control"] = "public, max-age=300"
    zones = db.scalars(
        select(StoreZone).where(StoreZone.store_id == store_id).order_by(StoreZone.sort_order, StoreZone.id)
    ).all()

    def point(x, y):
        return LayoutPoint(x=x, y=y) if x is not None and y is not None else None

    return StoreLayoutOut(
        store_id=store.id,
        entrance=point(store.entrance_x, store.entrance_y),
        checkout=point(store.checkout_x, store.checkout_y),
        zones=[LayoutZoneOut(id=z.id, name=z.name, x=z.x, y=z.y, source=z.source) for z in zones],
        approximate=any(z.source == "template" for z in zones) or not zones,
    )


@router.post("/feedback", response_model=FeedbackResponse, status_code=201)
def submit_feedback(body: FeedbackRequest, db: Database, caller: CallerDep):
    rate_limit(db, caller.subject, "feedback", get_settings().aisle_writes_per_hour)
    store = get_store(db, body.store_id)
    if store is None:
        raise HTTPException(status_code=404, detail="Store not found")
    if body.zone_id is not None:
        zone = db.get(StoreZone, body.zone_id)
        if zone is None or zone.store_id != store.id:
            raise HTTPException(status_code=422, detail="zone_id does not belong to this store")
    event = db.get(SearchEvent, body.search_id) if body.search_id else None
    intent = parse_intent(body.item)
    concept = find_concept(db, intent)
    observation = LocationObservation(
        store_id=store.id,
        search_event_id=event.id if event else None,
        concept_id=concept.id if concept else (event.concept_id if event else None),
        item_normalized=intent.normalized,
        verdict=body.verdict,
        zone_id=body.zone_id,
        aisle_text=body.aisle if body.verdict == "found" else None,
        note=body.note,
        # Who reported it, for counting agreement: the account, or the network when signed
        # out. Not the device id, which the client can make up.
        device_id=caller.subject[:64],
    )
    db.add(observation)
    db.commit()
    counts = None
    if body.zone_id is not None:
        zone_counts = counts_by_zone(observations_for(db, store, concept, intent.normalized)).get(body.zone_id)
        if zone_counts:
            counts = ReportCountsOut(found=zone_counts.found, not_here=zone_counts.not_here)
    return FeedbackResponse(
        id=observation.id, store_id=store.id, verdict=observation.verdict,
        zone_id=observation.zone_id, concept_id=observation.concept_id, reports=counts,
    )
