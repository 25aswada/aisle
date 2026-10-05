from concurrent.futures import ThreadPoolExecutor
from contextvars import copy_context
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
from ..plus.access import (
    FOLLOW_UP, PHOTO_SEARCH, ai_search_allowance, require_follow_up_allowed, require_signed_in, reserve_allowance,
    search_allowance,
)
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
    # 402 once a free account's (or a guest's) searches for today are used.
    counted = search_allowance(db, caller, at_store=body.store_id is not None)
    allowance = ai_search_allowance(db, caller) if model or explainer else None
    if allowance is None:
        # Out of AI answers for today (or no AI configured): Aisle's own data and wording.
        model = explainer = None
    try:
        result = search(db, body.query, body.store_id, model, device_id, explainer)
    except StoreNotFound:
        for used in (allowance, counted):
            if used:
                used.refund()
        raise HTTPException(status_code=404, detail="Store not found")
    if allowance and result.explanation is None and result.source != "model":
        allowance.refund()  # The AI added nothing to this answer.
    return result


# Follow-ups write the reply while working out whether it's a new item to find.
_follow_up_pool = ThreadPoolExecutor(max_workers=8, thread_name_prefix="aisle-follow-up")
# How much of a conversation goes to the model: the search and its answer that started
# it, then the latest turns, each cut to a length real replies stay well under.
MAX_CHAT_MESSAGES = 11
MAX_CHAT_MESSAGE_CHARS = 2000


def conversation_for_model(messages: list[dict]) -> list[dict]:
    """The conversation as the model sees it. Only the newest message keeps its photo:
    that's the one being paid for (the app sends no others), and earlier replies already
    describe the rest. Long conversations keep their start and their latest turns."""
    if len(messages) > MAX_CHAT_MESSAGES:
        messages = messages[:2] + messages[-(MAX_CHAT_MESSAGES - 2):]
    trimmed = []
    for index, message in enumerate(messages):
        message = {**message, "content": message.get("content", "")[:MAX_CHAT_MESSAGE_CHARS]}
        if message.get("image") and index != len(messages) - 1:
            del message["image"]
            message["content"] = message["content"] or "(a photo)"
        trimmed.append(message)
    return trimmed


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
    require_follow_up_allowed(db, caller, [m.model_dump(exclude_none=True) for m in body.messages])
    messages = conversation_for_model([m.model_dump(exclude_none=True) for m in body.messages])
    feature = PHOTO_SEARCH if messages[-1].get("image") else FOLLOW_UP
    allowance = reserve_allowance(db, caller, feature)
    place = f"{store.name} ({store.retailer_name}), {store.address}"
    # In this request's context, so the reply's AI call is charged to today's budget too.
    reply = _follow_up_pool.submit(copy_context().run, chat_safely, explainer, follow_up_system_prompt(place), messages)
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
