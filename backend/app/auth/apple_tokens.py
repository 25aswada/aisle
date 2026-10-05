"""Sign in with Apple tokens, kept so deleting an account can revoke its Apple sign-in.

App Review requires apps that offer Sign in with Apple to revoke the user's tokens when
they delete their account. At sign-in, and again when deleting the account, the app
sends Apple's one-time authorization code; we trade it with Apple for a refresh token and
revoke that on deletion (see apple_revocation).
Both calls need a client secret: a short-lived JWT signed with the app's Sign in with
Apple key. Without the key configured this is off, and sign-in works as before.
"""
from __future__ import annotations

import logging
import time
from typing import Protocol

import httpx
import jwt

log = logging.getLogger(__name__)

APPLE_AUDIENCE = "https://appleid.apple.com"
TOKEN_URL = "https://appleid.apple.com/auth/token"
REVOKE_URL = "https://appleid.apple.com/auth/revoke"


class AppleTokens(Protocol):
    def refresh_token(self, authorization_code: str) -> str | None: ...

    def revoke(self, refresh_token: str) -> bool: ...


def from_settings(settings) -> AppleTokens | None:
    """The token service, or None until the Sign in with Apple key is configured."""
    s = settings
    if not (s.apple_team_id and s.apple_signin_key_id and s.apple_signin_private_key):
        return None
    return AppleTokenService(s.apple_bundle_id, s.apple_team_id, s.apple_signin_key_id, s.apple_signin_private_key)


class AppleTokenService:
    def __init__(self, bundle_id: str, team_id: str, key_id: str, private_key: str,
                 client: httpx.Client | None = None):
        self.bundle_id = bundle_id
        self.team_id = team_id
        self.key_id = key_id
        # Heroku config vars keep the .p8 file's line breaks only if pasted with them.
        self.private_key = private_key.replace("\\n", "\n")
        self._client = client or httpx.Client(timeout=10)

    def client_secret(self) -> str:
        now = int(time.time())
        claims = {"iss": self.team_id, "iat": now, "exp": now + 300, "aud": APPLE_AUDIENCE, "sub": self.bundle_id}
        return jwt.encode(claims, self.private_key, algorithm="ES256", headers={"kid": self.key_id})

    def refresh_token(self, authorization_code: str) -> str | None:
        try:
            response = self._client.post(TOKEN_URL, data={
                "client_id": self.bundle_id, "client_secret": self.client_secret(),
                "code": authorization_code, "grant_type": "authorization_code",
            })
            response.raise_for_status()
            return response.json().get("refresh_token")
        except (httpx.HTTPError, ValueError, jwt.PyJWTError):
            log.warning("Couldn't trade an Apple authorization code for a refresh token", exc_info=True)
            return None

    def revoke(self, refresh_token: str) -> bool:
        try:
            response = self._client.post(REVOKE_URL, data={
                "client_id": self.bundle_id, "client_secret": self.client_secret(),
                "token": refresh_token, "token_type_hint": "refresh_token",
            })
            response.raise_for_status()
            return True
        except (httpx.HTTPError, jwt.PyJWTError):
            log.warning("Couldn't revoke an Apple sign-in", exc_info=True)
            return False
