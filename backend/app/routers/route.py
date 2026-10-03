from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..ai.providers import LocationModel, get_location_model
from ..database import get_db
from ..models import Store
from ..routing import plan_route
from ..schemas import RouteRequest, RouteResponse, RouteStop, RouteStopItem, UnplacedItem

router = APIRouter()
Database = Annotated[Session, Depends(get_db)]
Model = Annotated[LocationModel | None, Depends(get_location_model)]


@router.post("/route", response_model=RouteResponse)
def route(body: RouteRequest, db: Database, model: Model):
    store = db.get(Store, body.store_id)
    if store is None:
        raise HTTPException(status_code=404, detail="Store not found")
    planned = plan_route(db, store, [(i.id, i.text) for i in body.items], model)
    return RouteResponse(
        store_id=store.id,
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
