"""Shared family lists. Lists normally live only on the phone; sharing one moves it here
so everyone on it sees the same items.

Sharing needs Aisle+ (the owner's); joining with an invite code is free. Changes are
"upsert this item" or "delete this item": the latest write to an item wins, and every
change bumps the list's version so phones can tell when to fetch it again.
"""
import secrets
from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..database import get_db
from ..models import SharedList, SharedListItem, SharedListMember, User
from ..plus.access import require_plus
from ..schemas import (
    JoinSharedList, SharedItemIn, SharedItemOut, SharedListChanges, SharedListCreate, SharedListOut,
    SharedListRename, SharedListSummary, SharedMemberOut,
)
from .auth import CallerDep, SignedIn

router = APIRouter()
Database = Annotated[Session, Depends(get_db)]

MAX_ITEMS = 500
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O or 1/I mix-ups


def new_code(db: Session) -> str:
    while True:
        code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(6))
        if db.scalar(select(SharedList).where(SharedList.invite_code == code)) is None:
            return code


def normalize_code(code: str) -> str:
    return "".join(c for c in code.upper() if c.isalnum())


def members_out(shared: SharedList, user: User) -> list[SharedMemberOut]:
    people = sorted(shared.members, key=lambda m: (m.user_id != shared.owner_id, m.joined_at))
    return [
        SharedMemberOut(first_name=m.user.first_name or "Someone", is_owner=m.user_id == shared.owner_id,
                        is_you=m.user_id == user.id)
        for m in people
    ]


def list_out(shared: SharedList, user: User) -> SharedListOut:
    items = sorted(shared.items, key=lambda i: (i.position, i.updated_at))
    return SharedListOut(
        id=shared.id, name=shared.name, invite_code=shared.invite_code, version=shared.version,
        is_owner=shared.owner_id == user.id, members=members_out(shared, user),
        items=[SharedItemOut(id=i.id, text=i.text, quantity=i.quantity, category_name=i.category_name,
                             is_done=i.is_done, position=i.position) for i in items],
    )


def membership(db: Session, list_id: str, user: User) -> SharedList:
    shared = db.get(SharedList, list_id)
    if shared is None or not any(m.user_id == user.id for m in shared.members):
        raise HTTPException(status_code=404, detail="That list isn't shared with you anymore.")
    return shared


def apply_item(db: Session, shared: SharedList, item: SharedItemIn, now: datetime) -> None:
    row = db.get(SharedListItem, item.id)
    if row is not None and row.list_id != shared.id:
        return  # An id from another list: ignore rather than move items between lists.
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
def join_list(body: JoinSharedList, db: Database, session: SignedIn):
    user = session[0]
    shared = db.scalar(select(SharedList).where(SharedList.invite_code == normalize_code(body.code)))
    if shared is None:
        raise HTTPException(status_code=404, detail="That code didn't match a list. Check it and try again.")
    if not any(m.user_id == user.id for m in shared.members):
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
    shared = membership(db, list_id, user)
    now = datetime.now(timezone.utc)
    for change in body.changes:
        if change.op == "upsert" and change.item is not None:
            apply_item(db, shared, change.item, now)
        elif change.op == "delete" and change.id:
            row = db.get(SharedListItem, change.id)
            if row is not None and row.list_id == shared.id:
                shared.items.remove(row)
    if body.changes:
        touched(shared, now)
    db.commit()
    db.refresh(shared)
    return list_out(shared, user)


@router.patch("/lists/{list_id}", response_model=SharedListOut)
def rename_list(list_id: str, body: SharedListRename, db: Database, session: SignedIn):
    user = session[0]
    shared = membership(db, list_id, user)
    shared.name = body.name.strip()[:60]
    touched(shared, datetime.now(timezone.utc))
    db.commit()
    db.refresh(shared)
    return list_out(shared, user)


@router.delete("/lists/{list_id}", status_code=204)
def delete_or_leave(list_id: str, db: Database, session: SignedIn):
    """The owner deletes the list for everyone; anyone else leaves it."""
    user = session[0]
    shared = membership(db, list_id, user)
    if shared.owner_id == user.id:
        db.delete(shared)
    else:
        shared.members = [m for m in shared.members if m.user_id != user.id]
        touched(shared, datetime.now(timezone.utc))
    db.commit()
    return Response(status_code=204)
