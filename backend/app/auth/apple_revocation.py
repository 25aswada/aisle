"""Revoking a deleted account's Sign in with Apple, as App Review requires (5.1.1(v)).

When an account with an Apple sign-in is deleted, the app first asks Apple for a fresh
one-time code. We trade it for a refresh token and revoke that, falling back to the token
kept from sign-in. Deletion never waits on Apple: when it can't be revoked right then
(Apple unreachable, or the Sign in with Apple key not set yet), what's needed to try
again is kept in apple_revocations, and cleanup retries it with backoff until Apple
confirms or it's clearly not going to work.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import get_settings
from ..models import AppleRevocation, User
from .apple_tokens import AppleTokens

log = logging.getLogger(__name__)

# Apple's authorization codes work once, for five minutes.
CODE_LIFETIME = timedelta(minutes=5)
FIRST_RETRY = timedelta(hours=1)
LONGEST_WAIT = timedelta(days=1)
MAX_ATTEMPTS = 8
GIVE_UP_AFTER = timedelta(days=14)


def revoke_for_deletion(db: Session, user: User, authorization_code: str | None,
                        apple_tokens: AppleTokens | None) -> None:
    """Ends the account's Apple sign-in before it's deleted. Never stops the deletion: what
    can't be revoked now is added to the session for cleanup to retry, and saved when
    the deletion commits."""
    apple = [i for i in user.identities if i.provider == "apple"]
    if not apple:
        return
    stored = [i.apple_refresh_token for i in apple if i.apple_refresh_token]
    if apple_tokens is None:
        # Sentry picks up errors: in production this is an App Review requirement unmet.
        log.log(logging.ERROR if get_settings().on_heroku else logging.WARNING,
                "Deleted an Apple account without a Sign in with Apple key (APPLE_TEAM_ID, APPLE_SIGNIN_KEY_ID, "
                "APPLE_SIGNIN_PRIVATE_KEY); its Apple sign-in is kept to revoke later")
        _keep(db, stored, authorization_code)
        return
    fresh = apple_tokens.refresh_token(authorization_code) if authorization_code else None
    tokens = list(dict.fromkeys(t for t in (fresh, *stored) if t))
    # One revocation ends Aisle's Apple sign-in for that Apple ID; the fresh token goes first.
    if any(apple_tokens.revoke(token) for token in tokens):
        return
    if not tokens and not authorization_code:
        log.warning("Deleted an Apple account with no code or token to revoke its Apple sign-in with")
        return
    log.warning("Couldn't revoke a deleted account's Apple sign-in; cleanup will try again")
    _keep(db, tokens, authorization_code if fresh is None else None)


def _keep(db: Session, refresh_tokens: list[str], authorization_code: str | None) -> None:
    for token in refresh_tokens:
        db.add(AppleRevocation(refresh_token=token))
    if authorization_code and not refresh_tokens:
        db.add(AppleRevocation(authorization_code=authorization_code))


def retry_pending(db: Session, apple_tokens: AppleTokens | None, now: datetime | None = None) -> dict[str, int]:
    """Tries the revocations that are due. Run by cleanup every few hours."""
    now = now or datetime.now(timezone.utc)
    done = {"revoked": 0, "waiting": 0, "gave_up": 0}
    for pending in db.scalars(select(AppleRevocation).where(AppleRevocation.next_attempt_at <= now)).all():
        outcome = _retry(pending, apple_tokens, now)
        done[outcome] += 1
        if outcome != "waiting":
            db.delete(pending)
    db.commit()
    return done


def _retry(pending: AppleRevocation, apple_tokens: AppleTokens | None, now: datetime) -> str:
    created = pending.created_at if pending.created_at.tzinfo else pending.created_at.replace(tzinfo=timezone.utc)
    age = now - created
    if pending.refresh_token is None:
        if age > CODE_LIFETIME:
            log.error("Gave up revoking a deleted account's Apple sign-in: its code expired before it could be "
                      "traded (is the Sign in with Apple key set?)")
            return "gave_up"
        if apple_tokens is None:
            return "waiting"
        pending.refresh_token = apple_tokens.refresh_token(pending.authorization_code)
        pending.authorization_code = None
        if pending.refresh_token is None:
            log.error("Gave up revoking a deleted account's Apple sign-in: Apple didn't accept its code")
            return "gave_up"
    if apple_tokens is not None and apple_tokens.revoke(pending.refresh_token):
        return "revoked"
    if apple_tokens is not None:
        pending.attempts += 1
    if pending.attempts >= MAX_ATTEMPTS or age > GIVE_UP_AFTER:
        log.error("Gave up revoking a deleted account's Apple sign-in after %d tries over %d days",
                  pending.attempts, age.days)
        return "gave_up"
    if apple_tokens is not None:
        pending.next_attempt_at = now + min(FIRST_RETRY * 2 ** (pending.attempts - 1), LONGEST_WAIT)
    return "waiting"
