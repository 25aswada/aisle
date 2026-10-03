from pydantic import BaseModel, ConfigDict


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


class NearbyStoreResponse(StoreResponse):
    distance_miles: float


class NearbyResponse(BaseModel):
    stores: list[NearbyStoreResponse]
    message: str | None = None
