from typing import Annotated

from fastapi import APIRouter, Depends

from ..ai.explain import Explainer, read_list_safely
from ..ai.list_parser import parse_list
from ..ai.providers import get_explainer
from ..schemas import CategoryOut, ListParseRequest, ListParseResponse, ListScanRequest, ParsedListItem

router = APIRouter()
ExplainerDep = Annotated[Explainer | None, Depends(get_explainer)]


@router.post("/lists/parse", response_model=ListParseResponse)
def parse_shopping_list(body: ListParseRequest):
    """Split typed or pasted text into editable list items. Stateless: lists live on the device."""
    return _parsed(body.text)


@router.post("/lists/scan", response_model=ListParseResponse)
def scan_shopping_list(body: ListScanRequest, explainer: ExplainerDep):
    """Read a photographed shopping list, then split it like typed text. No items when
    there's no list in the photo, no AI key, or the provider couldn't read it."""
    text = read_list_safely(explainer, body.image)
    return _parsed(text) if text else ListParseResponse(items=[])


def _parsed(text: str) -> ListParseResponse:
    return ListParseResponse(items=[
        ParsedListItem(
            text=item.text,
            quantity=item.quantity,
            category=CategoryOut(slug=item.category.slug, name=item.category.name) if item.category else None,
        )
        for item in parse_list(text)
    ])
