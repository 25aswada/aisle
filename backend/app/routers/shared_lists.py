"""Shared family lists. Lists normally live only on the phone; sharing one moves it here
so everyone on it sees the same items.

Sharing needs Aisle+ (the owner's); joining with an invite code is free, while the
owner still has Aisle+. Invite codes are long enough, and joining limited enough, that
they can't be guessed. Changes are "upsert this item" or "delete this item": the latest
write to an item wins, and every change bumps the list's version so phones can tell
when to fetch it again.

The owner is in charge: only they see the invite code, can make a new one (the old one
stops working), rename the list, or take someone off it (who then can't join it again).
Anyone on a list can report it to Aisle, and leave it. If the owner deletes their
account, the list goes to whoever has been on it longest (see auth.accounts.delete_user).
"""
import logging
import secrets
from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..auth.codes import ResendEmailSender
from ..config import get_settings
from ..database import get_db
from ..legal import CONTACT_EMAIL
from ..limits import client_ip, rate_limit
from ..models import ContentReport, SharedList, SharedListBan, SharedListItem, SharedListMember, User
from ..plus.access import Caller, is_plus, require_plus
from ..schemas import (
    JoinSharedList, SharedItemIn, SharedItemOut, SharedListChanges, SharedListCreate, SharedListOut,
    SharedListRename, SharedListReport, SharedListSummary, SharedMemberOut,
)
from .auth import CallerDep, SignedIn

log = logging.getLogger(__name__)
router = APIRouter()
Database = Annotated[Session, Depends(get_db)]

MAX_ITEMS = 500
MAX_MEMBERS = 20
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O or 1/I mix-ups
# 32^8 codes: guessing one at the join limits below would take millions of years.
CODE_LENGTH = 8
# Tries to join a list (right code or not), per account and per network.
JOINS_PER_HOUR = 20
JOINS_PER_IP_PER_HOUR = 60
# Reports per account: each one emails support.
REPORTS_PER_HOUR = 10
NOT_OWNER = "Only the list's owner can do that."


def new_code(db: Session) -> str:
    while True:
        code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
        if db.scalar(select(SharedList).where(SharedList.invite_code == code)) is None:
            return code


def normalize_code(code: str) -> str:
    return "".join(c for c in code.upper() if c.isalnum())


def members_out(shared: SharedList, user: User) -> list[SharedMemberOut]:
    people = sorted(shared.members, key=lambda m: (m.user_id != shared.owner_id, m.joined_at))
    return [
        SharedMemberOut(id=m.id, first_name=m.user.first_name or "Someone", is_owner=m.user_id == shared.owner_id,
                        is_you=m.user_id == user.id)
        for m in people
    ]


def list_out(shared: SharedList, user: User) -> SharedListOut:
    items = sorted(shared.items, key=lambda i: (i.position, i.updated_at))
    is_owner = shared.owner_id == user.id
    return SharedListOut(
        id=shared.id, name=shared.name, invite_code=shared.invite_code if is_owner else None,
        version=shared.version, is_owner=is_owner, members=members_out(shared, user),
        items=[SharedItemOut(id=i.id, text=i.text, quantity=i.quantity, category_name=i.category_name,
                             is_done=i.is_done, position=i.position) for i in items],
    )


def membership(db: Session, list_id: str, user: User) -> SharedList:
    shared = db.get(SharedList, list_id)
    if shared is None or not any(m.user_id == user.id for m in shared.members):
        raise HTTPException(status_code=404, detail="That list isn't shared with you anymore.")
    return shared


def ownership(db: Session, list_id: str, user: User) -> SharedList:
    shared = membership(db, list_id, user)
    if shared.owner_id != user.id:
        raise HTTPException(status_code=403, detail=NOT_OWNER)
    return shared


def get_report_sender() -> ResendEmailSender | None:
    """Emails reports to support, with the Resend account that sends sign-in codes.
    Without it, reports are only stored."""
    s = get_settings()
    return ResendEmailSender(s.resend_api_key, s.aisle_email_from) if s.resend_api_key else None


ReportSender = Annotated[ResendEmailSender | None, Depends(get_report_sender)]


def apply_item(db: Session, shared: SharedList, item: SharedItemIn, now: datetime) -> None:
    # Ids come from the phones and are only unique within a list: the same id on another
    # list is another item.
    row = db.get(SharedListItem, (shared.id, item.id))
    if row is None:
        if len(shared.items) >= MAX_ITEMS:
            raise HTTPException(status_code=400, detail=f"A shared list holds up to {MAX_ITEMS} items.")
        row = SharedListItem(id=item.id, list_id=shared.id)
        shared.items.append(row)
    row.text = item.text.strip()[:200]
    row.quantity = item.quantity
    row.category_name = item.category_name
    row.is_done = item.is_done
    row.position = item.position
    row.updated_at = now


def touched(shared: SharedList, now: datetime) -> None:
    shared.version += 1
    shared.updated_at = now


def leave(shared: SharedList, user: User) -> None:
    shared.members = [m for m in shared.members if m.user_id != user.id]
    touched(shared, datetime.now(timezone.utc))


@router.get("/lists", response_model=list[SharedListSummary])
def my_lists(db: Database, session: SignedIn):
    user = session[0]
    lists = db.scalars(select(SharedList).join(SharedListMember).where(SharedListMember.user_id == user.id))
    return [
        SharedListSummary(id=s.id, name=s.name, version=s.version, is_owner=s.owner_id == user.id,
                          item_count=len(s.items), members=members_out(s, user))
        for s in lists
    ]


@router.post("/lists", response_model=SharedListOut, status_code=201)
def share_list(body: SharedListCreate, db: Database, session: SignedIn, caller: CallerDep):
    """Shares a list from the phone: it moves here with its items, and gets an invite code."""
    require_plus(db, caller, "shared_lists", "Sharing lists with your family is part of Aisle+.")
    user = session[0]
    now = datetime.now(timezone.utc)
    shared = SharedList(owner_id=user.id, name=body.name.strip()[:60], invite_code=new_code(db))
    db.add(shared)
    shared.members.append(SharedListMember(user_id=user.id))
    for item in body.items:
        apply_item(db, shared, item, now)
    db.commit()
    db.refresh(shared)
    return list_out(shared, user)


@router.post("/lists/join", response_model=SharedListOut)
def join_list(body: JoinSharedList, db: Database, session: SignedIn, request: Request):
    user = session[0]
    slow_down = "That's a lot of tries. Wait a little and check the code."
    rate_limit(db, f"user:{user.id}", "join", JOINS_PER_HOUR, slow_down)
    rate_limit(db, f"ip:{client_ip(request)}", "join", JOINS_PER_IP_PER_HOUR, slow_down)
    shared = db.scalar(select(SharedList).where(SharedList.invite_code == normalize_code(body.code)))
    if shared is None:
        raise HTTPException(status_code=404, detail="That code didn't match a list. Check it and try again.")
    if db.scalar(select(SharedListBan.id).where(SharedListBan.list_id == shared.id,
                                                SharedListBan.user_id == user.id)) is not None:
        raise HTTPException(status_code=403, detail="You can't join this list.")
    if not any(m.user_id == user.id for m in shared.members):
        if len(shared.members) >= MAX_MEMBERS:
            raise HTTPException(status_code=409, detail=f"That list already has {MAX_MEMBERS} people on it.")
        owner = db.get(User, shared.owner_id)
        if owner is None or not is_plus(db, Caller(user=owner, device_id=None, ip=None)):
            raise HTTPException(status_code=403, detail="This list's owner needs Aisle+ to add people. Ask them to renew it.")
        shared.members.append(SharedListMember(user_id=user.id))
        touched(shared, datetime.now(timezone.utc))
        db.commit()
        db.refresh(shared)
    return list_out(shared, user)


@router.get("/lists/{list_id}", response_model=SharedListOut)
def get_list(list_id: str, db: Database, session: SignedIn):
    return list_out(membership(db, list_id, session[0]), session[0])


@router.post("/lists/{list_id}/changes", response_model=SharedListOut)
def change_list(list_id: str, body: SharedListChanges, db: Database, session: SignedIn):
    user = session[0]
    rate_limit(db, f"user:{user.id}", "list_changes", get_settings().aisle_list_changes_per_hour)
    shared = membership(db, list_id, user)
    now = datetime.now(timezone.utc)
    for change in body.changes:
        if change.op == "upsert" and change.item is not None:
            apply_item(db, shared, change.item, now)
        elif change.op == "delete" and change.id:
            row = db.get(SharedListItem, (shared.id, change.id))
            if row is not None:
                shared.items.remove(row)
    if body.changes:
        touched(shared, now)
    db.commit()
    db.refresh(shared)
    return list_out(shared, user)


@router.patch("/lists/{list_id}", response_model=SharedListOut)
def rename_list(list_id: str, body: SharedListRename, db: Database, session: SignedIn):
    user = session[0]
    rate_limit(db, f"user:{user.id}", "list_settings", get_settings().aisle_writes_per_hour)
    shared = ownership(db, list_id, user)
    shared.name = body.name.strip()[:60]
    touched(shared, datetime.now(timezone.utc))
    db.commit()
    db.refresh(shared)
    return list_out(shared, user)


@router.post("/lists/{list_id}/code", response_model=SharedListOut)
def new_invite_code(list_id: str, db: Database, session: SignedIn):
    """The owner makes a new invite code. The old one stops working; nobody is removed."""
    user = session[0]
    rate_limit(db, f"user:{user.id}", "list_settings", get_settings().aisle_writes_per_hour)
    shared = ownership(db, list_id, user)
    shared.invite_code = new_code(db)
    touched(shared, datetime.now(timezone.utc))
    db.commit()
    db.refresh(shared)
    return list_out(shared, user)


@router.delete("/lists/{list_id}/members/{member_id}", response_model=SharedListOut)
def remove_member(list_id: str, member_id: int, db: Database, session: SignedIn):
    """The owner takes someone off the list. They can't join it again, whatever the code."""
    user = session[0]
    shared = ownership(db, list_id, user)
    member = next((m for m in shared.members if m.id == member_id), None)
    if member is None:
        raise HTTPException(status_code=404, detail="That person isn't on this list anymore.")
    if member.user_id == user.id:
        raise HTTPException(status_code=400, detail="You own this list. To leave it, delete it instead.")
    shared.members.remove(member)
    db.add(SharedListBan(list_id=shared.id, user_id=member.user_id))
    touched(shared, datetime.now(timezone.utc))
    db.commit()
    db.refresh(shared)
    return list_out(shared, user)


@router.post("/lists/{list_id}/report", status_code=204)
def report_list(list_id: str, body: SharedListReport, db: Database, session: SignedIn, sender: ReportSender):
    """Anyone on a list can report it to Aisle, and leave it in the same step. The report
    keeps a copy of the list as it is now, and goes to support by email."""
    user = session[0]
    rate_limit(db, f"user:{user.id}", "report", REPORTS_PER_HOUR,
               "That's a lot of reports. Email us if something needs a closer look.")
    shared = membership(db, list_id, user)
    items = sorted(shared.items, key=lambda i: (i.position, i.updated_at))
    report = ContentReport(
        reporter_id=user.id, list_id=shared.id, reason=body.reason, note=(body.note or "").strip() or None,
        snapshot={"name": shared.name, "owner_id": shared.owner_id, "items": [i.text for i in items]},
    )
    db.add(report)
    if body.leave and shared.owner_id != user.id:
        leave(shared, user)
    db.commit()
    if sender is not None:
        try:
            sender.send_text(CONTACT_EMAIL, f"Shared list reported: {body.reason}", report_email(report))
        except ConnectionError:
            log.warning("Couldn't email report %s; it's stored", report.id)
        else:
            report.emailed_at = datetime.now(timezone.utc)
            db.commit()
    return Response(status_code=204)


def report_email(report: ContentReport) -> str:
    items = report.snapshot["items"]
    shown = "\n".join(f"- {text}" for text in items[:50]) or "(no items)"
    more = f"\n...and {len(items) - 50} more" if len(items) > 50 else ""
    return (f"Report {report.id}: {report.reason}\n"
            f"Note: {report.note or '(none)'}\n"
            f"From user {report.reporter_id}, about list {report.list_id} (owner: user {report.snapshot['owner_id']}).\n\n"
            f"List name: {report.snapshot['name']}\n{shown}{more}\n\n"
            "The full copy is in content_reports. Set reviewed_at once it's been looked at.")


@router.delete("/lists/{list_id}", status_code=204)
def delete_or_leave(list_id: str, db: Database, session: SignedIn):
    """The owner deletes the list for everyone; anyone else leaves it (and can join again
    with the code, unlike someone the owner removed)."""
    user = session[0]
    shared = membership(db, list_id, user)
    if shared.owner_id == user.id:
        db.delete(shared)
    else:
        leave(shared, user)
    db.commit()
    return Response(status_code=204)
