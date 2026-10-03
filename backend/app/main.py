from math import asin, cos, radians, sin, sqrt
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Query
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from .database import get_db
from .models import Retailer, Store
from .routers import feedback as feedback_routes
from .routers import search as search_routes
from .schemas import NearbyResponse, NearbyStoreResponse, StoreResponse

app = FastAPI(title="Aisle API", version="0.2.0")
app.include_router(search_routes.router)
app.include_router(feedback_routes.router)
Database = Annotated[Session, Depends(get_db)]


def distance_miles(lat: float, lon: float, store: Store) -> float:
    """Haversine great-circle distance, using the mean Earth radius in miles."""
    lat1, lat2 = radians(lat), radians(store.latitude)
    dlat, dlon = lat2 - lat1, radians(store.longitude - lon)
    a = sin(dlat / 2) ** 2 + cos(lat1) * cos(lat2) * sin(dlon / 2) ** 2
    return 3958.7613 * 2 * asin(sqrt(min(1.0, max(0.0, a))))


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/stores/nearby", response_model=NearbyResponse)
def nearby(
    db: Database,
    lat: Annotated[float | None, Query(ge=-90, le=90)] = None,
    lon: Annotated[float | None, Query(ge=-180, le=180)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
):
    if lat is None or lon is None:
        return NearbyResponse(stores=[], message="Provide both lat and lon to find nearby stores.")
    ranked = sorted(
        ((distance_miles(lat, lon, store), store) for store in db.scalars(select(Store))),
        key=lambda pair: (pair[0], pair[1].id),
    )
    return NearbyResponse(stores=[
        NearbyStoreResponse(
            **StoreResponse.model_validate(store).model_dump(), distance_miles=distance
        )
        for distance, store in ranked[:limit]
    ])


@app.get("/stores/search", response_model=list[StoreResponse])
def search(
    db: Database,
    q: Annotated[str, Query(min_length=1, max_length=200)],
):
    term = q.strip().lower()
    if not term:
        return []
    # Treat SQL LIKE wildcard characters as literal manual-search text.
    term = term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    pattern = f"%{term}%"
    return db.scalars(
        select(Store).join(Store.retailer).where(or_(
            func.lower(Store.name).like(pattern, escape="\\"),
            func.lower(Store.address).like(pattern, escape="\\"),
            func.lower(Retailer.name).like(pattern, escape="\\"),
        )).order_by(Store.name, Store.id)
    ).all()


@app.get("/stores/{store_id}", response_model=StoreResponse)
def store_detail(store_id: int, db: Database):
    store = db.get(Store, store_id)
    if store is None:
        raise HTTPException(status_code=404, detail="Store not found")
    return store
