"""Basic in-store route order for a shopping list.

Each item is resolved like a search, items are grouped by store zone, and zones
are visited from the entrance to the checkout: greedy nearest neighbor, then a
2-opt pass, using Manhattan distance on the zone coordinates (shoppers walk along
aisles, not diagonally). Coordinates are approximate floor-plan positions.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.orm import Session

from .ai.intent import parse_intent
from .ai.providers import LocationModel
from .models import Store, StoreZone
from .resolver import Resolution, resolve

# Cap AI calls per route so one long list can't make the request slow.
MAX_MODEL_CALLS_PER_ROUTE = 5
DEFAULT_ENTRANCE = (0.5, 0.0)


class LimitedModel:
    def __init__(self, model: LocationModel, limit: int):
        self.name = model.name
        self._model = model
        self._remaining = limit

    def locate(self, intent, retailer_name, layout):
        if self._remaining <= 0:
            return None
        self._remaining -= 1
        return self._model.locate(intent, retailer_name, layout)


@dataclass
class PlannedItem:
    id: str
    text: str
    resolution: Resolution


@dataclass
class Stop:
    zone: StoreZone | None
    department: str
    items: list[PlannedItem] = field(default_factory=list)


@dataclass
class Route:
    stops: list[Stop]
    unplaced: list[tuple[PlannedItem, str]]
    distance: float


Point = tuple[float, float]


def manhattan(a: Point, b: Point) -> float:
    return abs(a[0] - b[0]) + abs(a[1] - b[1])


def path_length(points: list[Point], start: Point, end: Point | None) -> float:
    path = [start, *points] + ([end] if end else [])
    return sum(manhattan(path[i], path[i + 1]) for i in range(len(path) - 1))


def order_points(points: list[Point], start: Point, end: Point | None) -> list[int]:
    """Indexes of `points` in visiting order."""
    remaining = list(range(len(points)))
    order: list[int] = []
    here = start
    while remaining:
        nearest = min(remaining, key=lambda i: (manhattan(here, points[i]), i))
        order.append(nearest)
        remaining.remove(nearest)
        here = points[nearest]
    improved = True
    while improved:
        improved = False
        best = path_length([points[i] for i in order], start, end)
        for i in range(len(order) - 1):
            for j in range(i + 1, len(order)):
                candidate = order[:i] + order[i:j + 1][::-1] + order[j + 1:]
                length = path_length([points[k] for k in candidate], start, end)
                if length < best - 1e-9:
                    order, best, improved = candidate, length, True
    return order


def plan_route(
    db: Session, store: Store, items: list[tuple[str, str]], model: LocationModel | None
) -> Route:
    limited = LimitedModel(model, MAX_MODEL_CALLS_PER_ROUTE) if model else None
    zones = {z.id: z for z in db.scalars(select(StoreZone).where(StoreZone.store_id == store.id))}
    by_zone: dict[object, Stop] = {}
    unplaced: list[tuple[PlannedItem, str]] = []

    for item_id, text in items:
        planned = PlannedItem(item_id, text, resolve(db, parse_intent(text), store, limited))
        res = planned.resolution
        if res.department is None:
            unplaced.append((planned, "unknown"))
            continue
        if res.availability == "unlikely":
            unplaced.append((planned, "not_carried"))
            continue
        zone = zones.get(res.zone_id) if res.zone_id is not None else None
        key = zone.id if zone else f"department:{res.department}"
        stop = by_zone.setdefault(key, Stop(zone=zone, department=zone.name if zone else res.department))
        stop.items.append(planned)

    stops = list(by_zone.values())
    positioned = [s for s in stops if s.zone and s.zone.x is not None and s.zone.y is not None]
    floating = sorted(
        (s for s in stops if s not in positioned),
        key=lambda s: (s.zone.sort_order if s.zone else 10_000, s.department),
    )
    start = (store.entrance_x, store.entrance_y) if store.entrance_x is not None else DEFAULT_ENTRANCE
    end = (store.checkout_x, store.checkout_y) if store.checkout_x is not None else None
    points = [(s.zone.x, s.zone.y) for s in positioned]
    ordered = [positioned[i] for i in order_points(points, start, end)]
    distance = path_length([(s.zone.x, s.zone.y) for s in ordered], start, end) if ordered else 0.0
    # Stops without coordinates go last, before checkout, in layout order.
    return Route(stops=ordered + floating, unplaced=unplaced, distance=round(distance, 3))
