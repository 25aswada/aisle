from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ..ai.explain import Explainer, read_list_safely
from ..ai.list_parser import parse_list
from ..ai.providers import get_explainer
from ..database import get_db
from ..config import get_settings
from ..limits import rate_limit
from ..plus.access import PHOTO_SEARCH, reserve_allowance
from ..schemas import CategoryOut, ListParseRequest, ListParseResponse, ListScanRequest, ParsedListItem

from .auth import CallerDep, signed_in_for

router = APIRouter()
ExplainerDep = Annotated[Explainer | None, Depends(get_explainer)]
Database = Annotated[Session, Depends(get_db)]


@router.post("/lists/parse", response_model=ListParseResponse)
def parse_shopping_list(body: ListParseRequest, db: Database, caller: CallerDep):
    """Split typed or pasted text into editable list items. Stateless: lists live on the device."""
    rate_limit(db, caller.subject, "parse", get_settings().aisle_writes_per_hour)
    return _parsed(body.text)


@router.post("/lists/scan", response_model=ListParseResponse, dependencies=[signed_in_for("list scanning")])
def scan_shopping_list(body: ListScanRequest, explainer: ExplainerDep, db: Database, caller: CallerDep):
    """Read a photographed shopping list, then split it like typed text. No items when
    there's no list in the photo, no AI key, or the provider couldn't read it.
    Needs an account. A photo search: free shoppers get a few a day."""
    rate_limit(db, caller.subject, "photo", get_settings().aisle_photos_per_hour)
    allowance = reserve_allowance(db, caller, PHOTO_SEARCH)
    text = read_list_safely(explainer, body.image)
    parsed = _parsed(text) if text else ListParseResponse(items=[])
    if not parsed.items:
        allowance.refund()
    return parsed


def _parsed(text: str) -> ListParseResponse:
    return ListParseResponse(items=[
        ParsedListItem(
            text=item.text,
            quantity=item.quantity,
            category=CategoryOut(slug=item.category.slug, name=item.category.name) if item.category else None,
        )
        for item in parse_list(text)
    ])
