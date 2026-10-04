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
from ..config import get_settings
from ..limits import rate_limit
from ..plus.access import FOLLOW_UP, PHOTO_SEARCH, require_signed_in, reserve_allowance
from ..search import StoreNotFound, search
from .auth import CallerDep

router = APIRouter()
Database = Annotated[Session, Depends(get_db)]
Model = Annotated[LocationModel | None, Depends(get_location_model)]
ExplainerDep = Annotated[Explainer | None, Depends(get_explainer)]
DeviceID = Annotated[str | None, Header(alias="X-Aisle-Device", max_length=64)]


@router.post("/search", response_model=SearchResponse)
def search_item(
    body: SearchRequest, db: Database, model: Model, explainer: ExplainerDep, caller: CallerDep,
    device_id: DeviceID = None,
):
    rate_limit(db, caller.subject, "search", get_settings().aisle_searches_per_hour)
    try:
        return search(db, body.query, body.store_id, model, device_id, explainer)
    except StoreNotFound:
        raise HTTPException(status_code=404, detail="Store not found")


# Follow-ups write the reply while working out whether it's a new item to find.
_follow_up_pool = ThreadPoolExecutor(max_workers=8, thread_name_prefix="aisle-follow-up")
# Earlier photos in a conversation beyond this many are dropped before it goes to the model.
MAX_CHAT_PHOTOS = 2


def recent_photos_only(messages: list[dict]) -> list[dict]:
    """The conversation with only its latest photos, which keeps each request's cost down."""
    kept, trimmed = 0, []
    for message in reversed(messages):
        if message.get("image"):
            kept += 1
            if kept > MAX_CHAT_PHOTOS:
                message = {key: value for key, value in message.items() if key != "image"}
                message["content"] = message.get("content") or "(a photo)"
        trimmed.append(message)
    return trimmed[::-1]


@router.post("/chat", response_model=ChatResponse)
def follow_up(
    body: ChatRequest, db: Database, model: Model, explainer: ExplainerDep, caller: CallerDep,
    device_id: DeviceID = None,
):
    """The next reply in a conversation that started with a search at this store. When the
    shopper asks where to find a new item, that item's search comes back with the reply.

    Needs an account. Free shoppers get a few a day: a follow-up with a photo counts as a
    photo search."""
    require_signed_in(caller, "follow-ups")
    store = db.get(Store, body.store_id)
    if store is None:
        raise HTTPException(status_code=404, detail="Store not found")
    rate_limit(db, caller.subject, "follow_up", get_settings().aisle_follow_ups_per_hour)
    feature = PHOTO_SEARCH if body.messages[-1].image else FOLLOW_UP
    allowance = reserve_allowance(db, caller, feature)
    place = f"{store.name} ({store.retailer_name}), {store.address}"
    messages = recent_photos_only([m.model_dump(exclude_none=True) for m in body.messages])
    reply = _follow_up_pool.submit(chat_safely, explainer, follow_up_system_prompt(place), messages)
    item = wanted_item_safely(explainer, messages)
    # The reply already answers in context, so the search skips writing its own.
    result = search(db, item, store.id, model, device_id, explainer=None) if item else None
    answer = ChatResponse(reply=reply.result(), search=result)
    if not (answer.reply or answer.search):
        allowance.refund()
    return answer


@router.post("/identify", response_model=IdentifyResponse)
def identify(body: IdentifyRequest, db: Database, explainer: ExplainerDep, caller: CallerDep):
    """What the shopper photographed, as a search phrase the app then searches for.
    Needs an account. A photo search: free shoppers get a few a day."""
    require_signed_in(caller, "photo search")
    if body.store_id is not None and db.get(Store, body.store_id) is None:
        raise HTTPException(status_code=404, detail="Store not found")
    rate_limit(db, caller.subject, "photo", get_settings().aisle_photos_per_hour)
    allowance = reserve_allowance(db, caller, PHOTO_SEARCH)
    item = identify_safely(explainer, body.image, body.note)
    if not item:
        allowance.refund()
    return IdentifyResponse(item=item)
