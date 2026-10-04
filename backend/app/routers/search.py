from concurrent.futures import ThreadPoolExecutor
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException
from sqlalchemy.orm import Session

from ..ai.explain import Explainer, chat_safely, follow_up_system_prompt, identify_safely, wanted_item_safely
from ..ai.providers import LocationModel, get_explainer, get_location_model
from ..database import get_db
from ..models import Store
from ..schemas import (
    ChatRequest, ChatResponse, IdentifyRequest, IdentifyResponse, SearchRequest, SearchResponse,
)
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


# Follow-ups write the reply while working out whether it's a new item to find.
_follow_up_pool = ThreadPoolExecutor(max_workers=8, thread_name_prefix="aisle-follow-up")


@router.post("/chat", response_model=ChatResponse)
def follow_up(
    body: ChatRequest, db: Database, model: Model, explainer: ExplainerDep, device_id: DeviceID = None
):
    """The next reply in a conversation that started with a search at this store. When the
    shopper asks where to find a new item, that item's search comes back with the reply."""
    store = db.get(Store, body.store_id)
    if store is None:
        raise HTTPException(status_code=404, detail="Store not found")
    place = f"{store.name} ({store.retailer_name}), {store.address}"
    messages = [m.model_dump(exclude_none=True) for m in body.messages]
    reply = _follow_up_pool.submit(chat_safely, explainer, follow_up_system_prompt(place), messages)
    item = wanted_item_safely(explainer, messages)
    # The reply already answers in context, so the search skips writing its own.
    result = search(db, item, store.id, model, device_id, explainer=None) if item else None
    return ChatResponse(reply=reply.result(), search=result)


@router.post("/identify", response_model=IdentifyResponse)
def identify(body: IdentifyRequest, db: Database, explainer: ExplainerDep):
    """What the shopper photographed, as a search phrase the app then searches for."""
    if body.store_id is not None and db.get(Store, body.store_id) is None:
        raise HTTPException(status_code=404, detail="Store not found")
    return IdentifyResponse(item=identify_safely(explainer, body.image, body.note))
