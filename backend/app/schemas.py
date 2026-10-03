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


class SearchResponse(BaseModel):
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
