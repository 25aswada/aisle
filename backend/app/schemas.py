from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class RetailerResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    name: str


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
