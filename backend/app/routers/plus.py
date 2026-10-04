"""Aisle+: the app proves its subscription with signed App Store transactions, and asks
how much of the free tier is left today."""
import logging
from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import get_settings
from ..database import get_db
from ..models import PlusEntitlement, User
from ..plus.access import FOLLOW_UP, PHOTO_SEARCH, PLUS_PRODUCTS, Caller, active_entitlement, limit_for, used_today
from ..plus.appstore import InvalidTransaction, verify_transaction
from ..schemas import PlusStatus, PlusSync, UsageOut
from .auth import CallerDep

router = APIRouter()
Database = Annotated[Session, Depends(get_db)]
log = logging.getLogger(__name__)


def status_for(db: Session, caller: Caller) -> PlusStatus:
    entitlement = active_entitlement(db, caller)
    return PlusStatus(
        is_plus=entitlement is not None,
        expires_at=entitlement.expires_at if entitlement else None,
        product_id=entitlement.product_id if entitlement else None,
        photo_search=UsageOut(used=used_today(db, caller, PHOTO_SEARCH), limit=limit_for(PHOTO_SEARCH)),
        follow_up=UsageOut(used=used_today(db, caller, FOLLOW_UP), limit=limit_for(FOLLOW_UP)),
    )


@router.get("/plus/status", response_model=PlusStatus)
def plus_status(db: Database, caller: CallerDep):
    return status_for(db, caller)


@router.post("/plus/sync", response_model=PlusStatus)
def plus_sync(body: PlusSync, db: Database, caller: CallerDep):
    """Records the subscriptions the app's signed transactions prove, for the signed-in
    account. A subscription counts for the account it was bought for (its appAccountToken).
    With `claim` ("Restore purchases"), one bought for no account or for a deleted account
    moves to this one; one that belongs to another live account never does. Transactions
    that don't verify are ignored."""
    settings = get_settings()
    accepted = 0
    user = caller.user
    for jws in body.transactions:
        try:
            verified = verify_transaction(
                jws, bundle_id=settings.apple_bundle_id, product_ids=PLUS_PRODUCTS,
                allow_xcode=settings.aisle_plus_allow_xcode,
            )
        except InvalidTransaction as error:
            log.warning("Rejected an Aisle+ transaction: %s", error)
            continue
        accepted += 1
        if user is None:
            continue
        entitlement = db.scalar(select(PlusEntitlement).where(
            PlusEntitlement.original_transaction_id == verified.original_transaction_id))
        if not _belongs_to(db, user, verified.app_account_token, entitlement, claim=body.claim):
            continue
        if entitlement is None:
            entitlement = PlusEntitlement(original_transaction_id=verified.original_transaction_id)
            db.add(entitlement)
        entitlement.product_id = verified.product_id
        entitlement.environment = verified.environment
        entitlement.expires_at = verified.expires_at
        entitlement.revoked_at = verified.revoked_at
        entitlement.device_id = caller.device_id or entitlement.device_id
        entitlement.user_id = user.id
        entitlement.updated_at = datetime.now(timezone.utc)
    db.commit()
    if body.transactions and not accepted:
        raise HTTPException(status_code=400, detail="Those purchases couldn't be verified with the App Store.")
    return status_for(db, caller)


def _belongs_to(db: Session, user: User, token: str | None, entitlement: PlusEntitlement | None,
                *, claim: bool) -> bool:
    if entitlement is not None and entitlement.user_id not in (None, user.id):
        return False  # Another live account has it.
    if token == user.plus_token.lower():
        return True
    if not claim:
        return False
    # Restoring: fine if it was bought for no account, or for one that no longer exists.
    return token is None or db.scalar(select(User.id).where(User.plus_token == token)) is None
