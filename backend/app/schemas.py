from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class RetailerResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    name: str
    domain: str | None = None


class StoreResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    retailer_id: int
    name: str
    address: str
    latitude: float
    longitude: float
    external_place_id: str | None
    store_number: str | None
    retailer: RetailerResponse
    # Flat copy of retailer.name; the iOS client reads this field.
    retailer_name: str
    # logo.dev image for the retailer, or null without a domain or key.
    retailer_logo_url: str | None = None


class NearbyStoreResponse(StoreResponse):
    distance_miles: float


class NearbyResponse(BaseModel):
    stores: list[NearbyStoreResponse]
    message: str | None = None


Confidence = Literal["high", "medium", "low"]
Availability = Literal["likely", "unlikely", "unknown"]
LocationSource = Literal["database", "observations", "store_layout", "model", "fallback"]


class SearchRequest(BaseModel):
    query: str = Field(min_length=1, max_length=200)
    store_id: int | None = None

    @field_validator("query")
    @classmethod
    def query_not_blank(cls, value: str) -> str:
        value = " ".join(value.split())
        if not value:
            raise ValueError("query must not be blank")
        return value


class CategoryOut(BaseModel):
    slug: str
    name: str


class ConceptOut(BaseModel):
    id: int
    name: str


class LocationOut(BaseModel):
    department: str | None
    zone_id: int | None = None
    # Exact aisle/section text appears only when a database row supports it.
    aisle: str | None = None
    section: str | None = None
    neighbors: list[str] = []


class ReportCountsOut(BaseModel):
    found: int
    not_here: int


class SearchResponse(BaseModel):
    search_id: str | None = None
    query: str
    item: str
    modifiers: list[str]
    quantity: str | None
    store_id: int | None
    concept: ConceptOut | None
    category: CategoryOut | None
    location: LocationOut
    availability: Availability
    confidence: Confidence
    source: LocationSource
    # Shopper reports for the suggested zone at this store; null without a store or zone.
    reports: ReportCountsOut | None = None


class FeedbackRequest(BaseModel):
    store_id: int
    item: str = Field(min_length=1, max_length=200)
    verdict: Literal["found", "not_here"]
    search_id: str | None = Field(default=None, max_length=36)
    # Where the shopper found it (correction) or where it wasn't (not_here).
    zone_id: int | None = None
    aisle: str | None = Field(default=None, max_length=40)
    note: str | None = Field(default=None, max_length=280)

    @field_validator("item")
    @classmethod
    def item_not_blank(cls, value: str) -> str:
        value = " ".join(value.split())
        if not value:
            raise ValueError("item must not be blank")
        return value

    @field_validator("aisle", "note")
    @classmethod
    def blank_to_none(cls, value: str | None) -> str | None:
        value = " ".join((value or "").split())
        return value or None


class FeedbackResponse(BaseModel):
    id: int
    store_id: int
    verdict: Literal["found", "not_here"]
    zone_id: int | None
    concept_id: int | None
    reports: ReportCountsOut | None


class StoreZoneOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    name: str
    aisle_label: str | None
    source: str


class ListParseRequest(BaseModel):
    text: str = Field(max_length=2000)


class ParsedListItem(BaseModel):
    text: str
    quantity: str | None
    category: CategoryOut | None


class ListParseResponse(BaseModel):
    items: list[ParsedListItem]


class RouteItemIn(BaseModel):
    id: str = Field(min_length=1, max_length=64)
    text: str = Field(min_length=1, max_length=200)


class RouteRequest(BaseModel):
    store_id: int
    items: list[RouteItemIn] = Field(min_length=1, max_length=100)


class RouteStopItem(BaseModel):
    id: str
    text: str
    aisle: str | None
    section: str | None
    neighbors: list[str]
    confidence: Confidence
    source: LocationSource


class RouteStop(BaseModel):
    order: int
    zone_id: int | None
    department: str
    # Approximate floor-plan position (0..1); null when the zone has none.
    x: float | None
    y: float | None
    items: list[RouteStopItem]


class UnplacedItem(BaseModel):
    id: str
    text: str
    reason: Literal["unknown", "not_carried"]


class RouteResponse(BaseModel):
    store_id: int
    stops: list[RouteStop]
    unplaced: list[UnplacedItem]
    # Rough walking distance in floor-plan units, for comparing orders.
    distance: float


# Event names the app may send. Anything else is rejected so analytics stay a known set.
ANALYTICS_EVENT_NAMES = (
    "app_opened", "store_selected", "search_submitted", "search_failed", "recent_search_tapped",
    "feedback_sent", "list_items_added", "shopping_started", "shopping_item_found",
    "shopping_item_skipped", "shopping_finished",
)
AnalyticsValue = str | int | float | bool | None


class AnalyticsEventIn(BaseModel):
    name: Literal[ANALYTICS_EVENT_NAMES]  # type: ignore[valid-type]
    occurred_at: datetime | None = None
    properties: dict[str, AnalyticsValue] = Field(default_factory=dict, max_length=12)

    @field_validator("properties")
    @classmethod
    def small_values(cls, value: dict) -> dict:
        for key, item in value.items():
            if len(key) > 40:
                raise ValueError("property names are at most 40 characters")
            if isinstance(item, str) and len(item) > 80:
                raise ValueError("string properties are at most 80 characters")
        return value


class AnalyticsBatch(BaseModel):
    events: list[AnalyticsEventIn] = Field(min_length=1, max_length=50)


class AnalyticsAccepted(BaseModel):
    accepted: int
