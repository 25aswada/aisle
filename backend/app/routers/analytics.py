from typing import Annotated

from fastapi import APIRouter, Depends, Header
from sqlalchemy.orm import Session

from ..database import get_db
from ..models import AnalyticsEvent, utcnow
from ..schemas import AnalyticsAccepted, AnalyticsBatch

router = APIRouter()
Database = Annotated[Session, Depends(get_db)]
DeviceID = Annotated[str | None, Header(alias="X-Aisle-Device", max_length=64)]


@router.post("/events", response_model=AnalyticsAccepted, status_code=202)
def record_events(body: AnalyticsBatch, db: Database, device_id: DeviceID = None):
    now = utcnow()
    db.add_all(
        AnalyticsEvent(
            name=event.name, device_id=device_id, properties=event.properties,
            # Clamp client clocks that run ahead of the server.
            occurred_at=min(event.occurred_at, now) if event.occurred_at else now,
        )
        for event in body.events
    )
    db.commit()
    return AnalyticsAccepted(accepted=len(body.events))
