from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..ai.providers import LocationModel, get_location_model
from ..config import get_settings
from ..database import get_db
from ..limits import rate_limit
from ..plus.access import ai_search_allowance, guest_route_allowance, require_plus
from ..routing import Route, plan_multi_store, plan_route
from ..schemas import (
    MultiRouteRequest, MultiRouteResponse, RouteLeg, RouteRequest, RouteResponse, RouteStop, RouteStopItem,
    UnplacedItem,
)
from ..store_zones import get_store
from .auth import CallerDep

router = APIRouter()
Database = Annotated[Session, Depends(get_db)]
Model = Annotated[LocationModel | None, Depends(get_location_model)]


class CountingModel:
    """Passes guesses through, counting them, so a trip that never needed the AI isn't
    charged one of the day's AI answers."""

    def __init__(self, model: LocationModel):
        self.name = model.name
        self._model = model
        self.calls = 0

    def locate(self, intent, retailer_name, layout):
        self.calls += 1
        return self._model.locate(intent, retailer_name, layout)


def metered(db: Session, caller, model: LocationModel | None):
    """(model, allowance): a planned trip takes one of the day's AI answers, or runs on
    Aisle's own data when there are none left."""
    allowance = ai_search_allowance(db, caller) if model else None
    return (CountingModel(model), allowance) if allowance else (None, None)


def settle(model: CountingModel | None, allowance) -> None:
    if allowance and model and model.calls == 0:
        allowance.refund()


@router.post("/route", response_model=RouteResponse)
def route(body: RouteRequest, db: Database, model: Model, caller: CallerDep):
    rate_limit(db, caller.subject, "route", get_settings().aisle_routes_per_hour)
    store = get_store(db, body.store_id)
    if store is None:
        raise HTTPException(status_code=404, detail="Store not found")
    guest_route_allowance(db, caller)  # 402 once a guest's routes for today are used.
    model, allowance = metered(db, caller, model)
    planned = plan_route(db, store, [(i.id, i.text) for i in body.items], model)
    settle(model, allowance)
    return RouteResponse(store_id=store.id, **route_fields(planned))


@router.post("/route/multi", response_model=MultiRouteResponse)
def multi_route(body: MultiRouteRequest, db: Database, model: Model, caller: CallerDep):
    """One trip across several stores (Aisle+): each item goes to the first store likely
    to carry it, and each store gets its own walking route."""
    require_plus(db, caller, "multi_store", "Shopping more than one store in a trip is part of Aisle+.")
    rate_limit(db, caller.subject, "route", get_settings().aisle_routes_per_hour)
    if len(set(body.store_ids)) != len(body.store_ids):
        raise HTTPException(status_code=422, detail="Each store can only be in the trip once.")
    stores = [get_store(db, store_id) for store_id in body.store_ids]
    if any(store is None for store in stores):
        raise HTTPException(status_code=404, detail="Store not found")
    model, allowance = metered(db, caller, model)
    legs, nowhere = plan_multi_store(db, stores, [(i.id, i.text) for i in body.items], model)
    settle(model, allowance)
    return MultiRouteResponse(
        legs=[
            RouteLeg(
                store_id=leg.store.id, store_name=leg.store.name, retailer_name=leg.store.retailer.name,
                **route_fields(leg.route),
            )
            for leg in legs
        ],
        unplaced=[UnplacedItem(id=item_id, text=text, reason=reason) for item_id, text, reason in nowhere],
    )


def route_fields(planned: Route) -> dict:
    return dict(
        stops=[
            RouteStop(
                order=index,
                zone_id=stop.zone.id if stop.zone else None,
                department=stop.department,
                x=stop.zone.x if stop.zone else None,
                y=stop.zone.y if stop.zone else None,
                items=[
                    RouteStopItem(
                        id=item.id, text=item.text, aisle=item.resolution.aisle,
                        section=item.resolution.section, neighbors=item.resolution.neighbors,
                        confidence=item.resolution.confidence, source=item.resolution.source,
                    )
                    for item in stop.items
                ],
            )
            for index, stop in enumerate(planned.stops, start=1)
        ],
        unplaced=[UnplacedItem(id=item.id, text=item.text, reason=reason) for item, reason in planned.unplaced],
        distance=planned.distance,
    )
