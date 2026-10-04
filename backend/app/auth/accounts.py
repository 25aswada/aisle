"""Users, the ways they sign in, and their sessions.

A user can have several identities (Apple, Google, phone, email). Signing in with a
new identity whose *verified* email matches an existing user adds it to that user,
so "Continue with Google" after signing up by email code lands in the same account.
"""
from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timezone

from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session

from ..models import AuthSession, PlusEntitlement, UsageCounter, User, UserIdentity


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
    session.last_used_at = datetime.now(timezone.utc)
    db.commit()
    return user, session


def revoke(db: Session, session: AuthSession) -> None:
    session.revoked_at = datetime.now(timezone.utc)
    db.commit()


def delete_user(db: Session, user: User) -> None:
    """Deletes the account, its identities and sessions, its link to Aisle+ and its
    free-tier counts, so nothing carries over to a new account (SQLite can reuse the
    id). Searches and reports stay anonymous. Apple keeps billing a subscription
    until it's canceled in Settings; "Restore purchases" can move it to a new account."""
    db.execute(update(AuthSession).where(AuthSession.user_id == user.id)
               .values(revoked_at=datetime.now(timezone.utc)))
    db.execute(delete(PlusEntitlement).where(PlusEntitlement.user_id == user.id))
    db.execute(delete(UsageCounter).where(UsageCounter.subject == f"user:{user.id}"))
    db.delete(user)
    db.commit()
