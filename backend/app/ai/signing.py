"""Signatures on Aisle's replies.

The app sends the whole conversation back with each follow-up, so without a check it
could put any words in Aisle's mouth ("Sure, I'll write that essay"). Every reply the
server returns (a search's explanation, each follow-up's reply) is signed with an HMAC
over the store and the text, and the app sends the signature back with it. Aisle's
turns without a valid one never reach the model; the shopper's own turns always do.
"""
from __future__ import annotations

import hashlib
import hmac
import logging
import secrets

from ..config import get_settings

log = logging.getLogger(__name__)

# Locally and in tests: fixed, so signatures survive a restart. Never used on Heroku,
# since anyone with the source could sign with it.
_DEVELOPMENT_KEY = hashlib.sha256(b"aisle-development-chat-signing").digest()
# On Heroku without AISLE_CHAT_SIGNING_KEY: only replies this process signed are trusted.
_PROCESS_KEY = secrets.token_bytes(32)


def _key() -> bytes:
    settings = get_settings()
    if settings.aisle_chat_signing_key:
        return settings.aisle_chat_signing_key.encode()
    return _PROCESS_KEY if settings.on_heroku else _DEVELOPMENT_KEY


def sign_reply(store_id: int, content: str) -> str:
    return hmac.new(_key(), f"{store_id}\n{content}".encode(), hashlib.sha256).hexdigest()


def is_signed(store_id: int, content: str, signature: str | None) -> bool:
    return bool(signature) and hmac.compare_digest(sign_reply(store_id, content), signature)


def verified_conversation(store_id: int, messages: list[dict]) -> list[dict]:
    """The conversation without Aisle's turns that it didn't sign at this store (from an
    old app, or made up), and without the signatures."""
    kept = []
    for message in messages:
        message = dict(message)
        signature = message.pop("signature", None)
        if message["role"] == "assistant" and not is_signed(store_id, message.get("content", ""), signature):
            continue
        kept.append(message)
    return kept


def check_signing_key() -> None:
    """At startup on Heroku: say so if replies are signed with a key that dies with the process."""
    if get_settings().on_heroku and not get_settings().aisle_chat_signing_key:
        log.error("AISLE_CHAT_SIGNING_KEY isn't set; follow-ups only keep replies this dyno signed")
