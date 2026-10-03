from fastapi import APIRouter

from ..ai.list_parser import parse_list
from ..schemas import CategoryOut, ListParseRequest, ListParseResponse, ParsedListItem

router = APIRouter()


@router.post("/lists/parse", response_model=ListParseResponse)
def parse_shopping_list(body: ListParseRequest):
    """Split typed or pasted text into editable list items. Stateless: lists live on the device."""
    return ListParseResponse(items=[
        ParsedListItem(
            text=item.text,
            quantity=item.quantity,
            category=CategoryOut(slug=item.category.slug, name=item.category.name) if item.category else None,
        )
        for item in parse_list(body.text)
    ])
