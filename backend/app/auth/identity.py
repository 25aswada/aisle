"""Checks Sign in with Apple and Google ID tokens.

The app signs in with Apple or Google on the device and sends us the ID token (a JWT
the provider signed). We trust it only after checking its signature against the
provider's published keys, that it was issued to our app (audience), by the provider
(issuer), hasn't expired, and carries the nonce the app made for this sign-in.
"""
from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass
from functools import lru_cache
from typing import Protocol

import jwt

log = logging.getLogger(__name__)

APPLE_ISSUER = "https://appleid.apple.com"
APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys"
GOOGLE_ISSUERS = ("https://accounts.google.com", "accounts.google.com")
GOOGLE_KEYS_URL = "https://www.googleapis.com/oauth2/v3/certs"


class InvalidToken(Exception):
    """The ID token didn't check out: bad signature, wrong app, expired, or replayed."""


@dataclass(frozen=True)
class ProviderIdentity:
    subject: str
    email: str | None
    email_verified: bool
    given_name: str | None = None


class IdentityVerifier(Protocol):
    def apple(self, identity_token: str, nonce: str) -> ProviderIdentity: ...

    def google(self, id_token: str, nonce: str) -> ProviderIdentity: ...


@lru_cache(maxsize=4)
def _keys(url: str) -> jwt.PyJWKClient:
    # PyJWKClient caches the provider's keys and refetches when a token uses a new one.
    return jwt.PyJWKClient(url, cache_keys=True, lifespan=6 * 3600, timeout=10)


def _decode(token: str, keys_url: str, audience: str, issuer: str | tuple[str, ...]) -> dict:
    try:
        key = _keys(keys_url).get_signing_key_from_jwt(token)
        return jwt.decode(
            token, key.key, algorithms=["RS256"], audience=audience, issuer=issuer,
            options={"require": ["exp", "iat", "sub", "aud", "iss"]},
        )
    except jwt.PyJWKClientConnectionError as error:
        log.warning("Couldn't fetch sign-in keys from %s", keys_url)
        raise ConnectionError("sign-in keys unavailable") from error
    except jwt.PyJWTError as error:
        raise InvalidToken(str(error)) from error


def _truthy(value) -> bool:
    # Apple sends booleans as strings ("true"); Google sends real booleans.
    return value is True or value == "true"


class JWKSIdentityVerifier:
    """Verifies tokens against Apple's and Google's published signing keys."""

    def __init__(self, apple_bundle_id: str, google_client_id: str | None):
        self.apple_bundle_id = apple_bundle_id
        self.google_client_id = google_client_id

    def apple(self, identity_token: str, nonce: str) -> ProviderIdentity:
        claims = _decode(identity_token, APPLE_KEYS_URL, self.apple_bundle_id, APPLE_ISSUER)
        # The app sends Apple the SHA-256 of its nonce and us the nonce itself.
        if not nonce or claims.get("nonce") != hashlib.sha256(nonce.encode()).hexdigest():
            raise InvalidToken("nonce mismatch")
        return ProviderIdentity(
            subject=claims["sub"],
            email=(claims.get("email") or "").lower() or None,
            email_verified=_truthy(claims.get("email_verified")),
        )

    def google(self, id_token: str, nonce: str) -> ProviderIdentity:
        if not self.google_client_id:
            raise InvalidToken("Google sign-in isn't configured")
        claims = _decode(id_token, GOOGLE_KEYS_URL, self.google_client_id, GOOGLE_ISSUERS)
        if not nonce or claims.get("nonce") != nonce:
            raise InvalidToken("nonce mismatch")
        return ProviderIdentity(
            subject=claims["sub"],
            email=(claims.get("email") or "").lower() or None,
            email_verified=_truthy(claims.get("email_verified")),
            given_name=claims.get("given_name"),
        )
