"""Aisle+: the app proves its subscription with signed App Store transactions, and asks
how much of the free tier is left today. Apple also tells us directly (App Store Server
Notifications V2) when a subscription renews, lapses or is refunded."""
import logging
from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import get_settings
from ..database import get_db
from ..models import PlusEntitlement, User
from ..plus.access import (
    AI_SEARCH, FOLLOW_UP, PHOTO_SEARCH, PLUS_PRODUCTS, Caller, active_entitlement, limit_for, search_usage,
    used_today,
)
from ..plus.appstore import InvalidTransaction, VerifiedTransaction, verify_notification, verify_transaction
from ..schemas import AppStoreNotification, PlusStatus, PlusSync, UsageOut
from .auth import CallerDep

router = APIRouter()
Database = Annotated[Session, Depends(get_db)]
log = logging.getLogger(__name__)


def status_for(db: Session, caller: Caller) -> PlusStatus:
    entitlement = active_entitlement(db, caller)
    searches_used, searches_limit = search_usage(db, caller)
    return PlusStatus(
        is_plus=entitlement is not None,
        expires_at=entitlement.expires_at if entitlement else None,
        product_id=entitlement.product_id if entitlement else None,
        search=UsageOut(used=searches_used, limit=searches_limit),
        photo_search=UsageOut(used=used_today(db, caller, PHOTO_SEARCH), limit=limit_for(PHOTO_SEARCH)),
        follow_up=UsageOut(used=used_today(db, caller, FOLLOW_UP), limit=limit_for(FOLLOW_UP)),
        ai_search=UsageOut(used=used_today(db, caller, AI_SEARCH),
                           limit=limit_for(AI_SEARCH, signed_in=caller.user is not None)),
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
                allow_xcode=settings.allow_xcode_purchases,
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
        apply_transaction(entitlement, verified)
        entitlement.device_id = caller.device_id or entitlement.device_id
        entitlement.user_id = user.id
    db.commit()
    if body.transactions and not accepted:
        raise HTTPException(status_code=400, detail="Those purchases couldn't be verified with the App Store.")
    return status_for(db, caller)


def _aware(moment: datetime | None) -> datetime | None:
    return moment.replace(tzinfo=timezone.utc) if moment and moment.tzinfo is None else moment


def apply_transaction(entitlement: PlusEntitlement, verified: VerifiedTransaction, *, reinstate: bool = False) -> None:
    """Updates a subscription from one of its transactions. A refund or revocation ends it,
    and only a later purchase or renewal (or Apple reversing the refund: `reinstate`)
    brings it back, so a transaction saved from before the refund can't. Otherwise the
    latest expiry wins, so an older transaction arriving late can't shorten it."""
    entitlement.environment = verified.environment
    entitlement.updated_at = datetime.now(timezone.utc)
    if verified.revoked_at is not None:
        entitlement.revoked_at = verified.revoked_at
        entitlement.product_id = entitlement.product_id or verified.product_id
        return
    revoked = _aware(entitlement.revoked_at)
    if revoked is not None and not reinstate and (verified.purchased_at is None or verified.purchased_at <= revoked):
        return
    current = _aware(entitlement.expires_at)
    if revoked is not None or current is None or (verified.expires_at is not None and verified.expires_at >= current):
        entitlement.expires_at = verified.expires_at
        entitlement.product_id = verified.product_id
        entitlement.revoked_at = None


@router.post("/plus/notifications")
def app_store_notification(body: AppStoreNotification, db: Database):
    """App Store Server Notifications V2. Set this URL (for production and sandbox) in App
    Store Connect > the app > App Information. Renewals, lapses and refunds update the
    subscription even if the app is never opened again."""
    settings = get_settings()
    try:
        notice = verify_notification(body.signedPayload, bundle_id=settings.apple_bundle_id, product_ids=PLUS_PRODUCTS)
    except InvalidTransaction as error:
        log.warning("Rejected an App Store notification: %s", error)
        raise HTTPException(status_code=400, detail="Not a genuine App Store notification.")
    verified = notice.transaction
    if verified is None:
        return {"ok": True}
    entitlement = db.scalar(select(PlusEntitlement).where(
        PlusEntitlement.original_transaction_id == verified.original_transaction_id))
    if entitlement is None:
        # Bought on a phone that never synced: link it to the account it was bought for.
        owner = db.scalar(select(User).where(User.plus_token == verified.app_account_token)) \
            if verified.app_account_token else None
        entitlement = PlusEntitlement(original_transaction_id=verified.original_transaction_id,
                                      user_id=owner.id if owner else None)
        db.add(entitlement)
    apply_transaction(entitlement, verified, reinstate=notice.notification_type == "REFUND_REVERSED")
    if notice.notification_type in ("REFUND", "REVOKE") and entitlement.revoked_at is None:
        entitlement.revoked_at = datetime.now(timezone.utc)
    db.commit()
    log.info("App Store notification %s/%s for an Aisle+ subscription", notice.notification_type, notice.subtype)
    return {"ok": True}


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
