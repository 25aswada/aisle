from contextlib import asynccontextmanager
from math import asin, cos, degrees, radians, sin, sqrt
from typing import Annotated

import logging

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse
from sqlalchemy import and_, func, or_, select
from sqlalchemy.orm import Session

from .ai.signing import check_signing_key
from .cleanup import start_in_background as start_cleanup
from .config import get_settings
from .database import get_db
from .legal import privacy_page, support_page, terms_page
from .middleware import RequestGuard
from .monitoring import configure_logging, init_sentry
from .models import Retailer, Store
from .routers import analytics as analytics_routes
from .routers import auth as auth_routes
from .routers import feedback as feedback_routes
from .routers import lists as list_routes
from .routers import plus as plus_routes
from .routers import shared_lists as shared_list_routes
from .routers import route as route_routes
from .routers import search as search_routes
from .schemas import NearbyResponse, NearbyStoreResponse, StoreResponse

_on_heroku = get_settings().on_heroku
# Before the app exists, so Sentry hooks into FastAPI as it's built.
configure_logging(get_settings())
init_sentry(get_settings())


@asynccontextmanager
async def lifespan(_: FastAPI):
    if _on_heroku:
        start_cleanup()  # Deletes data past its retention, every few hours.
        check_signing_key()
    yield

# The API's interactive docs stay off in production; they map every route for anyone.
app = FastAPI(
    title="Aisle API", version="0.2.0",
    docs_url=None if _on_heroku else "/docs", redoc_url=None if _on_heroku else "/redoc",
    openapi_url=None if _on_heroku else "/openapi.json", lifespan=lifespan,
)
app.add_middleware(RequestGuard, redirect_http=_on_heroku)
app.include_router(search_routes.router)
app.include_router(feedback_routes.router)
app.include_router(list_routes.router)
app.include_router(route_routes.router)
app.include_router(analytics_routes.router)
app.include_router(auth_routes.router)
app.include_router(plus_routes.router)
app.include_router(shared_list_routes.router)
log = logging.getLogger(__name__)


@app.exception_handler(Exception)
async def unexpected_error(request: Request, exc: Exception):
    """Unexpected failures return JSON the app can show, never a stack trace."""
    log.exception("Unhandled error on %s %s", request.method, request.url.path)
    return JSONResponse(status_code=500, content={"detail": "Something went wrong. Please try again."})
Database = Annotated[Session, Depends(get_db)]


EARTH_RADIUS_MILES = 3958.7613
# Nearby search looks within growing circles until one holds enough stores.
NEARBY_RADII_MILES = (10, 40, 160, 640, 2560)
SEARCH_LIMIT = 50


def haversine_miles(lat: float, lon: float, lat2: float, lon2: float) -> float:
    """Great-circle distance, using the mean Earth radius in miles."""
    phi1, phi2 = radians(lat), radians(lat2)
    dlat, dlon = phi2 - phi1, radians(lon2 - lon)
    a = sin(dlat / 2) ** 2 + cos(phi1) * cos(phi2) * sin(dlon / 2) ** 2
    return EARTH_RADIUS_MILES * 2 * asin(sqrt(min(1.0, max(0.0, a))))


def distance_miles(lat: float, lon: float, store: Store) -> float:
    return haversine_miles(lat, lon, store.latitude, store.longitude)


def within_box(lat: float, lon: float, miles: float):
    """A latitude/longitude box holding every point within `miles` of (lat, lon)."""
    angle = miles / EARTH_RADIUS_MILES
    dlat = degrees(angle)
    conditions = [Store.latitude.between(lat - dlat, lat + dlat)]
    if abs(lat) + dlat < 90 and sin(angle) < cos(radians(lat)):
        dlon = degrees(asin(sin(angle) / cos(radians(lat))))
        west, east = lon - dlon, lon + dlon
        if west < -180:  # The box crosses the antimeridian.
            conditions.append(or_(Store.longitude >= west + 360, Store.longitude <= east))
        elif east > 180:
            conditions.append(or_(Store.longitude >= west, Store.longitude <= east - 360))
        else:
            conditions.append(Store.longitude.between(west, east))
    return and_(*conditions)


def with_distances(lat: float, lon: float, stores) -> list[tuple[float, Store]]:
    return sorted(((distance_miles(lat, lon, s), s) for s in stores), key=lambda pair: (pair[0], pair[1].id))


def nearby_response(distance: float, store: Store) -> NearbyStoreResponse:
    return NearbyStoreResponse(**StoreResponse.model_validate(store).model_dump(), distance_miles=distance)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


# Public pages the App Store links to.
@app.get("/privacy", response_class=HTMLResponse, include_in_schema=False)
def privacy() -> str:
    return privacy_page()


@app.get("/terms", response_class=HTMLResponse, include_in_schema=False)
def terms() -> str:
    return terms_page()


@app.get("/support", response_class=HTMLResponse, include_in_schema=False)
def support() -> str:
    return support_page()


@app.head("/health", include_in_schema=False)
def health_head() -> None:
    """For uptime monitors that check with HEAD."""


@app.get("/stores/nearby", response_model=NearbyResponse)
def nearby(
    db: Database,
    lat: Annotated[float | None, Query(ge=-90, le=90)] = None,
    lon: Annotated[float | None, Query(ge=-180, le=180)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
):
    if lat is None or lon is None:
        return NearbyResponse(stores=[], message="Provide both lat and lon to find nearby stores.")
    # Only stores inside the circle are certainly nearer than any store outside it.
    for miles in NEARBY_RADII_MILES:
        ranked = [
            pair for pair in with_distances(lat, lon, db.scalars(select(Store).where(within_box(lat, lon, miles))))
            if pair[0] <= miles
        ]
        if len(ranked) >= limit:
            break
    else:
        # Nothing much for thousands of miles. Rank every store by its coordinates alone
        # (cheap, unlike loading them all), then load just the nearest.
        points = db.execute(select(Store.id, Store.latitude, Store.longitude)).all()
        nearest = sorted(points, key=lambda p: (haversine_miles(lat, lon, p.latitude, p.longitude), p.id))[:limit]
        stores = db.scalars(select(Store).where(Store.id.in_([p.id for p in nearest]))).all()
        ranked = with_distances(lat, lon, stores)
    return NearbyResponse(stores=[nearby_response(d, s) for d, s in ranked[:limit]])


@app.get("/stores/search", response_model=list[NearbyStoreResponse] | list[StoreResponse])
def search(
    db: Database,
    q: Annotated[str, Query(min_length=1, max_length=200)],
    lat: Annotated[float | None, Query(ge=-90, le=90)] = None,
    lon: Annotated[float | None, Query(ge=-180, le=180)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = SEARCH_LIMIT,
):
    """Stores whose name, retailer or address contain every word of the query, so
    "giant eagle strongsville" works. With lat and lon, nearest first, with distances."""
    words = q.lower().split()
    if not words:
        return []
    matches = []
    for word in words:
        # Treat SQL LIKE wildcard characters as literal manual-search text.
        word = word.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        pattern = f"%{word}%"
        matches.append(or_(
            func.lower(Store.name).like(pattern, escape="\\"),
            func.lower(Store.address).like(pattern, escape="\\"),
            func.lower(Retailer.name).like(pattern, escape="\\"),
        ))
    query = select(Store).join(Store.retailer).where(*matches)
    if lat is None or lon is None:
        return db.scalars(query.order_by(Store.name, Store.id).limit(limit)).all()
    # Rank in SQL by flat-map distance (close enough to pick the nearest few), then
    # report true distances.
    squeeze = cos(radians(lat))
    flat = (Store.latitude - lat) * (Store.latitude - lat) + \
        (Store.longitude - lon) * (Store.longitude - lon) * squeeze * squeeze
    nearest = db.scalars(query.order_by(flat, Store.id).limit(limit)).all()
    return [nearby_response(d, s) for d, s in with_distances(lat, lon, nearest)]


@app.get("/stores/{store_id}", response_model=StoreResponse)
def store_detail(store_id: int, db: Database):
    store = db.get(Store, store_id)
    if store is None:
        raise HTTPException(status_code=404, detail="Store not found")
    return store
