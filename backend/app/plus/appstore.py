"""Checks StoreKit 2 signed transactions (JWS) the app sends after a purchase or restore.

A transaction is a JWS whose header carries its certificate chain (x5c: leaf,
intermediate, root). We trust it only when the chain leads to Apple Root CA - G3
(pinned below), each certificate is valid and issued by the next, the leaf and
intermediate carry Apple's App Store receipt-signing extensions, the ES256 signature
checks out with the leaf key, and it's for this app and one of its Aisle+ products.

Transactions from Xcode's local StoreKit testing are signed by a throwaway local
certificate instead. Those are accepted only when `allow_xcode` is on (development).
"""
from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path

import jwt
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.x509.oid import ObjectIdentifier

ROOT_PATH = Path(__file__).with_name("apple_root_ca_g3.pem")
# Apple's marker extensions: on the App Store receipt-signing leaf and on the WWDR intermediate.
LEAF_OID = ObjectIdentifier("1.2.840.113635.100.6.11.1")
INTERMEDIATE_OID = ObjectIdentifier("1.2.840.113635.100.6.2.1")


class InvalidTransaction(Exception):
    """Not a genuine App Store transaction for this app."""


@dataclass(frozen=True)
class VerifiedTransaction:
    original_transaction_id: str
    transaction_id: str
    product_id: str
    expires_at: datetime | None
    revoked_at: datetime | None
    environment: str  # Production, Sandbox or Xcode
    # The account the app bought it for (StoreKit's appAccountToken), lowercase; None if unset.
    app_account_token: str | None = None


@lru_cache(maxsize=1)
def apple_root() -> x509.Certificate:
    return x509.load_pem_x509_certificate(ROOT_PATH.read_bytes())


def _b64url(part: str) -> bytes:
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


def _moment(milliseconds) -> datetime | None:
    return datetime.fromtimestamp(milliseconds / 1000, tz=timezone.utc) if milliseconds else None


def _verified_payload(jws: str, *, allow_xcode: bool, root: x509.Certificate | None,
                      now: datetime | None) -> dict:
    """The JWS payload, once its signature and certificate chain check out."""
    try:
        header_part, payload_part, _ = jws.split(".")
        header = json.loads(_b64url(header_part))
        payload = json.loads(_b64url(payload_part))
        chain = [x509.load_der_x509_certificate(base64.b64decode(c)) for c in header.get("x5c", [])]
    except (ValueError, TypeError) as error:
        raise InvalidTransaction("not a signed transaction") from error
    if header.get("alg") != "ES256" or not chain:
        raise InvalidTransaction("unexpected signature")

    if payload.get("environment") == "Xcode":
        if not allow_xcode:
            raise InvalidTransaction("Xcode test transactions aren't accepted here")
    else:
        _check_chain(chain, root or apple_root(), now or datetime.now(timezone.utc))

    try:
        jwt.PyJWS().decode(jws, chain[0].public_key(), algorithms=["ES256"])
    except jwt.PyJWTError as error:
        raise InvalidTransaction("bad signature") from error
    return payload


def verify_transaction(
    jws: str, *, bundle_id: str, product_ids: set[str], allow_xcode: bool = False,
    root: x509.Certificate | None = None, now: datetime | None = None,
) -> VerifiedTransaction:
    payload = _verified_payload(jws, allow_xcode=allow_xcode, root=root, now=now)
    environment = payload.get("environment", "")
    if payload.get("bundleId") != bundle_id:
        raise InvalidTransaction("transaction is for another app")
    if payload.get("productId") not in product_ids:
        raise InvalidTransaction("not an Aisle+ product")
    return VerifiedTransaction(
        original_transaction_id=str(payload["originalTransactionId"]),
        transaction_id=str(payload["transactionId"]),
        product_id=payload["productId"],
        expires_at=_moment(payload.get("expiresDate")),
        revoked_at=_moment(payload.get("revocationDate")),
        environment=environment,
        app_account_token=(payload.get("appAccountToken") or "").lower() or None,
    )


def _check_chain(chain: list[x509.Certificate], root: x509.Certificate, now: datetime) -> None:
    if len(chain) != 3:
        raise InvalidTransaction("expected a three-certificate chain")
    leaf, intermediate, presented_root = chain
    if presented_root.fingerprint(hashes.SHA256()) != root.fingerprint(hashes.SHA256()):
        raise InvalidTransaction("not signed by Apple")
    for cert in chain:
        if not cert.not_valid_before_utc <= now <= cert.not_valid_after_utc:
            raise InvalidTransaction("certificate expired")
    try:
        leaf.verify_directly_issued_by(intermediate)
        intermediate.verify_directly_issued_by(root)
    except (ValueError, TypeError, InvalidSignature) as error:
        raise InvalidTransaction("broken certificate chain") from error
    for cert, oid in ((leaf, LEAF_OID), (intermediate, INTERMEDIATE_OID)):
        try:
            cert.extensions.get_extension_for_oid(oid)
        except x509.ExtensionNotFound as error:
            raise InvalidTransaction("not an App Store signing certificate") from error


@dataclass(frozen=True)
class VerifiedNotification:
    """An App Store Server Notification (V2): what happened, and to which transaction."""
    notification_type: str  # e.g. DID_RENEW, EXPIRED, REFUND, REVOKE
    subtype: str | None
    transaction: VerifiedTransaction | None


def verify_notification(
    signed_payload: str, *, bundle_id: str, product_ids: set[str],
    root: x509.Certificate | None = None, now: datetime | None = None,
) -> VerifiedNotification:
    """Checks a notification Apple sent us, and the signed transaction inside it."""
    payload = _verified_payload(signed_payload, allow_xcode=False, root=root, now=now)
    data = payload.get("data") or {}
    if data.get("bundleId") != bundle_id:
        raise InvalidTransaction("notification is for another app")
    signed_transaction = data.get("signedTransactionInfo")
    transaction = verify_transaction(
        signed_transaction, bundle_id=bundle_id, product_ids=product_ids, root=root, now=now,
    ) if signed_transaction else None
    return VerifiedNotification(
        notification_type=str(payload.get("notificationType", "")), subtype=payload.get("subtype"),
        transaction=transaction,
    )
