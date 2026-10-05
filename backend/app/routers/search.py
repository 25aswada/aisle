from concurrent.futures import ThreadPoolExecutor
from contextvars import copy_context
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException
from sqlalchemy.orm import Session

from ..ai.explain import (
    FLAGGED_REPLY, OFF_TOPIC_REPLY, UNSAFE_REPLY, Explainer, Moderator, chat_safely, flagged_safely,
    follow_up_system_prompt, identify_safely, topic_safely,
)
from ..ai.providers import LocationModel, get_explainer, get_location_model, get_moderator
from ..ai.signing import sign_reply, verified_conversation
from ..database import get_db
from ..models import Store
from ..schemas import (
    ChatRequest, ChatResponse, IdentifyRequest, IdentifyResponse, SearchRequest, SearchResponse,
)
from ..config import get_settings
from ..limits import rate_limit
from ..plus.access import (
    FOLLOW_UP, PHOTO_SEARCH, ai_search_allowance, require_follow_up_allowed, reserve_allowance, search_allowance,
)
from ..search import StoreNotFound, search
from .auth import CallerDep, signed_in_for

router = APIRouter()
Database = Annotated[Session, Depends(get_db)]
Model = Annotated[LocationModel | None, Depends(get_location_model)]
ExplainerDep = Annotated[Explainer | None, Depends(get_explainer)]
ModeratorDep = Annotated[Moderator | None, Depends(get_moderator)]
DeviceID = Annotated[str | None, Header(alias="X-Aisle-Device", max_length=64)]


@router.post("/search", response_model=SearchResponse)
def search_item(
    body: SearchRequest, db: Database, model: Model, explainer: ExplainerDep, moderator: ModeratorDep,
    caller: CallerDep, device_id: DeviceID = None,
):
    rate_limit(db, caller.subject, "search", get_settings().aisle_searches_per_hour)
    # 402 once a free account's (or a guest's) searches for today are used.
    counted = search_allowance(db, caller, at_store=body.store_id is not None)
    allowance = ai_search_allowance(db, caller) if model or explainer else None
    if allowance is None:
        # Out of AI answers for today (or no AI configured): Aisle's own data and wording.
        model = explainer = None
    try:
        result = search(db, body.query, body.store_id, model, device_id, explainer, moderator)
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


def without_redirects(messages: list[dict]) -> list[dict]:
    """The conversation without messages Aisle turned away and its redirects, so they
    neither count as follow-ups nor stay in the model's view. Only signed turns are left
    by this point, so a redirect can't be made up."""
    kept: list[dict] = []
    for message in messages:
        if message["role"] == "assistant" and message["content"] in (OFF_TOPIC_REPLY, FLAGGED_REPLY):
            if len(kept) > 1 and kept[-1]["role"] == "user":  # Never the search that started it.
                kept.pop()
            continue
        kept.append(message)
    return kept


def aisle_says(store_id: int, reply: str | None, result: SearchResponse | None = None) -> ChatResponse:
    """A follow-up's answer, its reply signed so the app can send it back as Aisle's turn."""
    signature = sign_reply(store_id, reply) if reply else None
    return ChatResponse(reply=reply, search=result, reply_signature=signature)


@router.post("/chat", response_model=ChatResponse, dependencies=[signed_in_for("follow-ups")])
def follow_up(
    body: ChatRequest, db: Database, model: Model, explainer: ExplainerDep, moderator: ModeratorDep,
    caller: CallerDep, device_id: DeviceID = None,
):
    """The next reply in a conversation that started with a search at this store. When the
    shopper asks where to find a new item, that item's search comes back with the reply.
    Aisle's earlier turns only reach the model with the signature they were sent with.
    A message Aisle isn't for (or one moderation flags) gets a short redirect instead of
    an answer, and isn't counted.

    Needs an account. Free shoppers get a few a day: a follow-up with a photo counts as a
    photo search."""
    store = db.get(Store, body.store_id)
    if store is None:
        raise HTTPException(status_code=404, detail="Store not found")
    rate_limit(db, caller.subject, "follow_up", get_settings().aisle_follow_ups_per_hour)
    sent = [m.model_dump(exclude_none=True) for m in body.messages]
    sent = without_redirects(verified_conversation(store.id, sent))
    require_follow_up_allowed(db, caller, sent)
    messages = conversation_for_model(sent)
    newest = messages[-1]
    feature = PHOTO_SEARCH if newest.get("image") else FOLLOW_UP
    allowance = reserve_allowance(db, caller, feature)
    place = f"{store.name} ({store.retailer_name}), {store.address}"
    # The reply is written while the message is checked, so on-topic answers wait no
    # longer. In this request's context, so the reply's AI call is charged to today's
    # budget too.
    reply = _follow_up_pool.submit(copy_context().run, chat_safely, explainer, follow_up_system_prompt(place), messages)
    screened = None
    if moderator is not None:
        screened = _follow_up_pool.submit(flagged_safely, moderator, newest["content"], newest.get("image"))
    topic = topic_safely(explainer, messages)
    flagged = bool(screened and screened.result())
    if flagged or not topic.on_topic:
        reply.cancel()  # Not shown, even if it's already being written.
        allowance.refund()
        return aisle_says(store.id, FLAGGED_REPLY if flagged else OFF_TOPIC_REPLY)
    # The reply already answers in context, so the search skips writing its own.
    result = search(db, topic.item, store.id, model, device_id, explainer=None) if topic.item else None
    text = reply.result()
    if text == OFF_TOPIC_REPLY:  # The model found it out of scope after all.
        allowance.refund()
        return aisle_says(store.id, text)
    if flagged_safely(moderator, text):
        text = UNSAFE_REPLY
    if not ((text and text != UNSAFE_REPLY) or result):
        allowance.refund()
    return aisle_says(store.id, text, result)


@router.post("/identify", response_model=IdentifyResponse, dependencies=[signed_in_for("photo search")])
def identify(body: IdentifyRequest, db: Database, explainer: ExplainerDep, caller: CallerDep):
    """What the shopper photographed, as a search phrase the app then searches for.
    Needs an account. A photo search: free shoppers get a few a day."""
    if body.store_id is not None and db.get(Store, body.store_id) is None:
        raise HTTPException(status_code=404, detail="Store not found")
    rate_limit(db, caller.subject, "photo", get_settings().aisle_photos_per_hour)
    allowance = reserve_allowance(db, caller, PHOTO_SEARCH)
    item = identify_safely(explainer, body.image, body.note)
    if not item:
        allowance.refund()
    return IdentifyResponse(item=item)
