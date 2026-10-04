"""Users, the ways they sign in, and their sessions.

A user can have several identities (Apple, Google, phone, email). Signing in with a
new identity whose *verified* email matches an existing user adds it to that user,
so "Continue with Google" after signing up by email code lands in the same account.
"""
from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session

from ..models import AuthSession, CodeRequest, EmailCode, PlusEntitlement, UsageCounter, User, UserIdentity


def sign_in(
    db: Session, provider: str, subject: str, *, email: str | None = None, email_verified: bool = False,
    phone: str | None = None, given_name: str | None = None,
) -> tuple[User, bool]:
    """The user for this identity, creating one if needed. Returns (user, is_new)."""
    identity = db.scalar(select(UserIdentity).where(
        UserIdentity.provider == provider, UserIdentity.subject == subject))
    if identity is not None:
        user = identity.user
        if email and not identity.email:
            identity.email = email
        db.commit()
        return user, False

    verified_email = email if email_verified else None
    user = db.scalar(select(User).where(User.email == verified_email)) if verified_email else None
    is_new = user is None
    if user is None:
        user = User(
            first_name=(given_name or "").strip()[:40], email=verified_email, phone=phone,
        )
        db.add(user)
        db.flush()
    else:
        if phone and not user.phone:
            user.phone = phone
        if given_name and not user.first_name:
            user.first_name = given_name.strip()[:40]
    db.add(UserIdentity(user_id=user.id, provider=provider, subject=subject, email=email))
    db.commit()
    db.refresh(user)
    return user, is_new


class PhoneTaken(Exception):
    """The number already signs in to a different account."""


def add_phone(db: Session, user: User, phone: str) -> User:
    """Makes a verified phone number a way into this account, so signing in with it later
    finds this account instead of making a new one. Replaces the account's old number."""
    owner = db.scalar(select(UserIdentity).where(
        UserIdentity.provider == "phone", UserIdentity.subject == phone))
    if owner is not None and owner.user_id != user.id:
        raise PhoneTaken(phone)
    if owner is None:
        for old in [i for i in user.identities if i.provider == "phone"]:
            user.identities.remove(old)
        user.identities.append(UserIdentity(provider="phone", subject=phone))
    user.phone = phone
    db.commit()
    db.refresh(user)
    return user


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def create_session(db: Session, user: User, device_id: str | None) -> str:
    """A new random token for this device. Only its hash is stored."""
    token = secrets.token_urlsafe(32)
    db.add(AuthSession(user_id=user.id, token_hash=_hash(token), device_id=device_id))
    db.commit()
    return token


def user_for_token(db: Session, token: str) -> tuple[User, AuthSession] | None:
    session = db.scalar(select(AuthSession).where(
        AuthSession.token_hash == _hash(token), AuthSession.revoked_at.is_(None)))
    if session is None:
        return None
    user = db.get(User, session.user_id)
    if user is None:
        return None
    now = datetime.now(timezone.utc)
    last = session.last_used_at
    if last is None or (last if last.tzinfo else last.replace(tzinfo=timezone.utc)) < now - timedelta(hours=1):
        session.last_used_at = now  # At most hourly, not a write on every request.
        db.commit()
    return user, session


def revoke(db: Session, session: AuthSession) -> None:
    session.revoked_at = datetime.now(timezone.utc)
    db.commit()


def delete_user(db: Session, user: User) -> None:
    """Deletes the account, its identities and sessions, its link to Aisle+ and its
    free-tier counts, so nothing carries over to a new account (SQLite can reuse the
    id), and the sign-in code records for its phone number and emails. Searches and
    reports stay anonymous. Apple keeps billing a subscription
    until it's canceled in Settings; "Restore purchases" can move it to a new account."""
    db.execute(update(AuthSession).where(AuthSession.user_id == user.id)
               .values(revoked_at=datetime.now(timezone.utc)))
    db.execute(delete(PlusEntitlement).where(PlusEntitlement.user_id == user.id))
    db.execute(delete(UsageCounter).where(UsageCounter.subject == f"user:{user.id}"))
    # Sign-in code records hold the phone number or email; they go too.
    contacts = {c for c in (user.email, user.phone, *(i.email for i in user.identities),
                            *(i.subject for i in user.identities if i.provider in ("phone", "email"))) if c}
    if contacts:
        db.execute(delete(CodeRequest).where(CodeRequest.target.in_(contacts)))
        db.execute(delete(EmailCode).where(EmailCode.email.in_(contacts)))
    db.delete(user)
    db.commit()
