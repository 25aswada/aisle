"""Sign-in codes by SMS (Twilio Verify) and email (our own codes, sent with Resend).

Twilio Verify makes, sends and checks SMS codes itself. Email codes are ours: six
random digits, stored only as a hash, valid for 10 minutes and 5 tries.

Every send is rate limited by phone/email, device and IP, so a script can't run up
the Twilio bill or flood someone's inbox.
"""
from __future__ import annotations

import hashlib
import hmac
import logging
import re
import secrets
from datetime import datetime, timedelta, timezone
from typing import Protocol

import httpx
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..models import CodeRequest, EmailCode

log = logging.getLogger(__name__)

CODE_TTL = timedelta(minutes=10)
MAX_CODE_ATTEMPTS = 5
RESEND_COOLDOWN = timedelta(seconds=30)
# Sends allowed per hour.
PER_TARGET_HOURLY = 5
PER_DEVICE_HOURLY = 10
PER_IP_HOURLY = 20


class CodeProblem(Exception):
    """Something the shopper can fix or wait out. `status` is the HTTP status to return."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


# MARK: - Normalizing what people type

_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s.]+$")


def normalize_email(raw: str) -> str:
    email = raw.strip().lower()
    if len(email) > 320 or not _EMAIL.match(email):
        raise CodeProblem(400, "That email doesn't look right.")
    return email


def normalize_phone(raw: str) -> str:
    """E.164, e.g. "+12155550123". Ten digits with no country code are taken as US."""
    has_plus = raw.strip().startswith("+")
    digits = re.sub(r"\D", "", raw)
    if not has_plus:
        if len(digits) == 10:
            digits = "1" + digits
        elif not (len(digits) == 11 and digits.startswith("1")):
            raise CodeProblem(400, "That phone number doesn't look right. Include the country code if it's not a US number.")
    if not 8 <= len(digits) <= 15 or digits.startswith("0"):
        raise CodeProblem(400, "That phone number doesn't look right.")
    return "+" + digits


# MARK: - Rate limits

def check_rate_limits(db: Session, channel: str, target: str, device_id: str | None, ip: str | None,
                      now: datetime | None = None) -> None:
    now = now or datetime.now(timezone.utc)
    hour_ago = now - timedelta(hours=1)

    def count(*conditions) -> int:
        return db.scalar(select(func.count()).select_from(CodeRequest).where(
            CodeRequest.created_at >= hour_ago, *conditions)) or 0

    last = db.scalar(select(func.max(CodeRequest.created_at)).where(CodeRequest.target == target))
    if last is not None and _aware(last) > now - RESEND_COOLDOWN:
        wait = int((_aware(last) + RESEND_COOLDOWN - now).total_seconds()) + 1
        raise CodeProblem(429, f"A code is already on its way. You can ask for another in {wait} seconds.")
    if count(CodeRequest.target == target) >= PER_TARGET_HOURLY:
        raise CodeProblem(429, "Too many codes for this one. Try again in an hour.")
    if device_id and count(CodeRequest.device_id == device_id) >= PER_DEVICE_HOURLY:
        raise CodeProblem(429, "Too many codes from this phone. Try again in an hour.")
    if ip and count(CodeRequest.ip == ip) >= PER_IP_HOURLY:
        raise CodeProblem(429, "Too many codes from this network. Try again later.")


def record_code_request(db: Session, channel: str, target: str, device_id: str | None, ip: str | None) -> None:
    db.add(CodeRequest(channel=channel, target=target, device_id=device_id, ip=ip))
    db.commit()


def _aware(moment: datetime) -> datetime:
    # SQLite hands back naive datetimes; they were stored as UTC.
    return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)


# MARK: - SMS (Twilio Verify)

class PhoneVerifier(Protocol):
    def send(self, phone: str) -> None: ...

    def check(self, phone: str, code: str) -> bool: ...


class TwilioPhoneVerifier:
    """Twilio Verify: it makes, texts and checks the code; we never see it."""

    def __init__(self, account_sid: str, auth_token: str, service_sid: str, client: httpx.Client | None = None):
        self._base = f"https://verify.twilio.com/v2/Services/{service_sid}"
        self._auth = (account_sid, auth_token)
        self._client = client or httpx.Client(timeout=10)

    def send(self, phone: str) -> None:
        response = self._post("/Verifications", {"To": phone, "Channel": "sms"})
        if response.status_code in (200, 201):
            return
        code = _twilio_error(response)
        if code in (60200, 21211, 21614):
            raise CodeProblem(400, "That phone number doesn't look right.")
        if code in (60203, 60410) or response.status_code == 429:
            raise CodeProblem(429, "Too many codes for this number. Try again later.")
        if code == 60205:
            raise CodeProblem(400, "That number can't get texts. Try a mobile number or use email.")
        log.warning("Twilio send failed: HTTP %s, code %s", response.status_code, code)
        raise ConnectionError("Twilio send failed")

    def check(self, phone: str, code: str) -> bool:
        response = self._post("/VerificationCheck", {"To": phone, "Code": code})
        if response.status_code == 404:
            # Expired, already used, or never sent.
            raise CodeProblem(400, "That code has expired. Ask for a new one.")
        if response.status_code == 429 or _twilio_error(response) == 60202:
            raise CodeProblem(429, "Too many wrong tries. Ask for a new code.")
        if response.status_code != 200:
            log.warning("Twilio check failed: HTTP %s", response.status_code)
            raise ConnectionError("Twilio check failed")
        return response.json().get("status") == "approved"

    def _post(self, path: str, data: dict) -> httpx.Response:
        try:
            return self._client.post(self._base + path, data=data, auth=self._auth)
        except httpx.HTTPError as error:
            raise ConnectionError("Twilio unreachable") from error


def _twilio_error(response: httpx.Response) -> int | None:
    try:
        return response.json().get("code")
    except ValueError:
        return None


# MARK: - Email (our codes, sent with Resend)

class EmailSender(Protocol):
    def send_code(self, email: str, code: str) -> None: ...


class ResendEmailSender:
    def __init__(self, api_key: str, sender: str, client: httpx.Client | None = None):
        self._api_key = api_key
        self._sender = sender
        self._client = client or httpx.Client(timeout=10)

    def send_code(self, email: str, code: str) -> None:
        payload = {
            "from": self._sender,
            "to": [email],
            "subject": f"{code} is your Aisle code",
            "text": f"Your Aisle sign-in code is {code}.\n\nIt expires in 10 minutes. "
                    "If you didn't ask for it, you can ignore this email.",
            "html": _email_html(code),
        }
        try:
            response = self._client.post(
                "https://api.resend.com/emails", json=payload,
                headers={"Authorization": f"Bearer {self._api_key}"},
            )
        except httpx.HTTPError as error:
            raise ConnectionError("Resend unreachable") from error
        if response.status_code == 429:
            raise CodeProblem(429, "Too many emails right now. Try again in a minute.")
        if response.status_code == 422:
            raise CodeProblem(400, "We couldn't send to that email. Check it and try again.")
        if response.status_code not in (200, 201):
            log.warning("Resend send failed: HTTP %s", response.status_code)
            raise ConnectionError("Resend send failed")


def _email_html(code: str) -> str:
    return (
        '<div style="font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:420px;margin:0 auto;'
        'padding:32px 24px;color:#1f1b24">'
        '<p style="font-size:15px;margin:0 0 8px">Your Aisle sign-in code</p>'
        f'<p style="font-size:36px;font-weight:700;letter-spacing:6px;margin:0 0 16px">{code}</p>'
        '<p style="font-size:14px;color:#6b6570;margin:0">It expires in 10 minutes. '
        "If you didn't ask for it, you can ignore this email.</p></div>"
    )


def _hash_code(email: str, code: str) -> str:
    return hashlib.sha256(f"{email}:{code}".encode()).hexdigest()


def issue_email_code(db: Session, email: str, sender: EmailSender) -> None:
    """Makes a new code, sends it, then stores its hash. Older codes stop working."""
    code = f"{secrets.randbelow(1_000_000):06d}"
    sender.send_code(email, code)
    now = datetime.now(timezone.utc)
    for old in db.scalars(select(EmailCode).where(EmailCode.email == email, EmailCode.consumed_at.is_(None))):
        old.consumed_at = now
    db.add(EmailCode(email=email, code_hash=_hash_code(email, code), expires_at=now + CODE_TTL))
    db.commit()


def check_email_code(db: Session, email: str, code: str) -> bool:
    """True once per code. Wrong guesses count against the code's 5 tries."""
    now = datetime.now(timezone.utc)
    current = db.scalar(
        select(EmailCode).where(EmailCode.email == email, EmailCode.consumed_at.is_(None))
        .order_by(EmailCode.id.desc())
    )
    if current is None or _aware(current.expires_at) <= now:
        raise CodeProblem(400, "That code has expired. Ask for a new one.")
    if current.attempts >= MAX_CODE_ATTEMPTS:
        raise CodeProblem(429, "Too many wrong tries. Ask for a new code.")
    current.attempts += 1
    if hmac.compare_digest(current.code_hash, _hash_code(email, code)):
        current.consumed_at = now
        db.commit()
        return True
    db.commit()
    return False
