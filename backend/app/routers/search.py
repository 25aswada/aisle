from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..ai.providers import LocationModel, get_location_model
from ..database import get_db
from ..schemas import SearchRequest, SearchResponse
from ..search import StoreNotFound, search

router = APIRouter()
Database = Annotated[Session, Depends(get_db)]
Model = Annotated[LocationModel | None, Depends(get_location_model)]


@router.post("/search", response_model=SearchResponse)
def search_item(body: SearchRequest, db: Database, model: Model):
    try:
        return search(db, body.query, body.store_id, model)
    except StoreNotFound:
        raise HTTPException(status_code=404, detail="Store not found")
