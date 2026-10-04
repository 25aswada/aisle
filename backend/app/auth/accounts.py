"""Users, the ways they sign in, and their sessions.

A user can have several identities (Apple, Google, phone, email). Signing in with a
new identity whose *verified* email matches an existing user adds it to that user,
so "Continue with Google" after signing up by email code lands in the same account.

Daily limits are per account, so deleting an account must not reset them: its current
counts are kept under a hash of each way it signed in, and a new account made with any
of those picks them back up. Each network can only make so many accounts a day.
"""
from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..config import get_settings
from ..limits import bump, day_window, hour_window, request_ip
from ..models import AuthSession, EmailCode, PlusEntitlement, UsageCounter, UsedSignInNonce, User, UserIdentity

# A session nobody has used for this long is over; the app asks to sign in again.
SESSION_IDLE_LIMIT = timedelta(days=90)


class TooManyNewAccounts(Exception):
    """This network has made its accounts for today."""


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
        _spend_new_account_budget(db)
        user = User(
            first_name=(given_name or "").strip()[:40], email=verified_email, phone=phone,
        )
        db.add(user)
        db.flush()
        _pick_up_usage(db, user, _usage_keys([(provider, subject)], verified_email, phone))
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
    last = (last if last.tzinfo else last.replace(tzinfo=timezone.utc)) if last else None
    if last is not None and last < now - SESSION_IDLE_LIMIT:
        session.revoked_at = now
        db.commit()
        return None
    if last is None or last < now - timedelta(hours=1):
        session.last_used_at = now  # At most hourly, not a write on every request.
        db.commit()
    return user, session


def first_use_of_nonce(db: Session, provider: str, nonce: str) -> bool:
    """Records an Apple or Google sign-in's nonce; False if it was used before, so the
    same ID token can't sign in twice. Atomic: parallel replays can't both pass."""
    db.add(UsedSignInNonce(nonce_hash=hashlib.sha256(f"{provider}:{nonce}".encode()).hexdigest()))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        return False
    return True


def has_account(db: Session, channel: str, target: str) -> bool:
    """Whether this phone number or email already signs in to an account."""
    provider = "phone" if channel == "sms" else "email"
    if db.scalar(select(UserIdentity.id).where(
            UserIdentity.provider == provider, UserIdentity.subject == target).limit(1)) is not None:
        return True
    column = User.phone if channel == "sms" else User.email
    return db.scalar(select(User.id).where(column == target).limit(1)) is not None


def _spend_new_account_budget(db: Session) -> None:
    ip = request_ip.get()
    if ip is None:
        return  # Scripts and tests outside a request aren't limited.
    if bump(db, f"ip:{ip}", "new_accounts", day_window()) > get_settings().aisle_new_accounts_per_ip_per_day:
        raise TooManyNewAccounts(ip)


def _usage_keys(identities, email: str | None, phone: str | None) -> set[str]:
    """Where a deleted account's counts wait: a hash of each way it signed in."""
    ways = {f"{provider}:{subject}" for provider, subject in identities}
    ways |= {f"email:{email}"} if email else set()
    ways |= {f"phone:{phone}"} if phone else set()
    return {"gone:" + hashlib.sha256(way.encode()).hexdigest() for way in ways}


def _current_windows() -> list[str]:
    # Today's daily counts and this hour's fair-use counts; older ones no longer limit.
    return [day_window(), hour_window()]


def _pick_up_usage(db: Session, user: User, keys: set[str]) -> None:
    """A new account made with a deleted account's sign-in starts where that one left off."""
    best: dict[tuple[str, str], int] = {}
    for counter in db.scalars(select(UsageCounter).where(
            UsageCounter.subject.in_(keys), UsageCounter.day.in_(_current_windows()))):
        key = (counter.feature, counter.day)
        best[key] = max(best.get(key, 0), counter.count)
    for (feature, day), count in best.items():
        db.add(UsageCounter(subject=f"user:{user.id}", feature=feature, day=day, count=count))


def _set_aside_usage(db: Session, user: User) -> None:
    keys = _usage_keys([(i.provider, i.subject) for i in user.identities], user.email, user.phone)
    counters = db.scalars(select(UsageCounter).where(
        UsageCounter.subject == f"user:{user.id}", UsageCounter.day.in_(_current_windows()))).all()
    for key in keys:
        for counter in counters:
            kept = db.scalar(select(UsageCounter).where(
                UsageCounter.subject == key, UsageCounter.feature == counter.feature, UsageCounter.day == counter.day))
            if kept is None:
                db.add(UsageCounter(subject=key, feature=counter.feature, day=counter.day, count=counter.count))
            else:
                kept.count = max(kept.count, counter.count)


def revoke(db: Session, session: AuthSession) -> None:
    session.revoked_at = datetime.now(timezone.utc)
    db.commit()


def delete_user(db: Session, user: User) -> None:
    """Deletes the account, its identities and sessions, its link to Aisle+, and the
    emailed codes for its addresses. Today's limit counts move to a hash of each way it
    signed in (kept about a week, like all counts), so signing up again doesn't reset
    them; nothing else carries over (SQLite can reuse the id). Sign-in code records only
    hold hashes and go after two days. Searches and reports stay anonymous. Apple keeps
    billing a subscription until it's canceled in Settings; "Restore purchases" can move
    it to a new account."""
    db.execute(update(AuthSession).where(AuthSession.user_id == user.id)
               .values(revoked_at=datetime.now(timezone.utc)))
    db.execute(delete(PlusEntitlement).where(PlusEntitlement.user_id == user.id))
    _set_aside_usage(db, user)
    db.execute(delete(UsageCounter).where(UsageCounter.subject == f"user:{user.id}"))
    emails = {e for e in (user.email, *(i.email for i in user.identities),
                          *(i.subject for i in user.identities if i.provider == "email")) if e}
    if emails:
        db.execute(delete(EmailCode).where(EmailCode.email.in_(emails)))
    db.delete(user)
    db.commit()
