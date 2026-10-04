from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException
from sqlalchemy.orm import Session

from ..ai.explain import Explainer
from ..ai.providers import LocationModel, get_explainer, get_location_model
from ..database import get_db
from ..schemas import SearchRequest, SearchResponse
from ..search import StoreNotFound, search

router = APIRouter()
Database = Annotated[Session, Depends(get_db)]
Model = Annotated[LocationModel | None, Depends(get_location_model)]
ExplainerDep = Annotated[Explainer | None, Depends(get_explainer)]
DeviceID = Annotated[str | None, Header(alias="X-Aisle-Device", max_length=64)]


@router.post("/search", response_model=SearchResponse)
def search_item(
    body: SearchRequest, db: Database, model: Model, explainer: ExplainerDep, device_id: DeviceID = None
):
    try:
        return search(db, body.query, body.store_id, model, device_id, explainer)
    except StoreNotFound:
        raise HTTPException(status_code=404, detail="Store not found")
