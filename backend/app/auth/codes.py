"""Sign-in codes by SMS (Twilio Verify) and email (our own codes, sent with Resend).

Twilio Verify makes, sends and checks SMS codes itself. Email codes are ours: six
random digits, stored only as a hash, valid for 10 minutes and 5 tries.

Every send is rate limited by phone/email, device and IP, and all sends together are
capped per hour and day, so a script can't run up the Twilio bill or flood someone's
inbox; past the overall cap, only people who already have an account still get codes.
The records behind these limits keep a hash of the phone or email, not the address,
so they can outlive a deleted account (a couple of days) and deleting can't reset them.
Texts only go to the countries in settings (the US and Canada by default).
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import re
import secrets
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Protocol

import httpx
from sqlalchemy import func, select, text, update
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
    if not 8 <= len(digits) <= 15 or digits.startswith("0") or (digits.startswith("1") and len(digits) != 11):
        raise CodeProblem(400, "That phone number doesn't look right.")
    return "+" + digits


def canonical_email(email: str) -> str:
    """One mailbox's many spellings as one: "+tags" dropped, and Gmail's dots too."""
    local, _, domain = email.partition("@")
    local = local.split("+", 1)[0] or local
    if domain in ("gmail.com", "googlemail.com"):
        local, domain = local.replace(".", ""), "gmail.com"
    return f"{local}@{domain}"


def target_key(channel: str, target: str) -> str:
    """What code records keep for a phone or email: a hash, never the address."""
    if channel == "email":
        target = canonical_email(target)
    return hashlib.sha256(f"{channel}:{target}".encode()).hexdigest()


# MARK: - Rate limits

def check_rate_limits(db: Session, channel: str, target: str, device_id: str | None, ip: str | None,
                      now: datetime | None = None) -> None:
    now = now or datetime.now(timezone.utc)
    hour_ago = now - timedelta(hours=1)
    target = target_key(channel, target)

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


# Area codes inside +1 that belong to other countries (the Caribbean and Bermuda). Texts
# there cost far more and are a favorite of SMS-pumping fraud, so +1 alone doesn't allow
# them; list one in settings (e.g. "1876") to text it.
OTHER_NANP_COUNTRIES = {
    "242", "246", "264", "268", "284", "345", "441", "473", "649", "658", "664", "721",
    "758", "767", "784", "809", "829", "849", "868", "869", "876",
}
# Premium-rate numbers.
PREMIUM_NANP = {"900", "976"}


def check_sms_country(phone: str, country_codes: tuple[str, ...]) -> None:
    digits = phone[1:]
    allowed = any(digits.startswith(code) for code in country_codes)
    if allowed and digits.startswith("1") and digits[1:4] in OTHER_NANP_COUNTRIES | PREMIUM_NANP:
        allowed = any(len(code) > 1 and digits.startswith(code) for code in country_codes)
    if not allowed:
        raise CodeProblem(400, "Aisle can only text US and Canadian numbers for now. Try email instead.")


# Taken while one send's limits are checked and recorded, so parallel requests line up.
_CODE_LOCK = 0x4149534C45  # "AISLE"


def reserve_code_request(db: Session, channel: str, target: str, device_id: str | None, ip: str | None,
                         *, per_hour: int, per_day: int, returning: bool = False,
                         now: datetime | None = None) -> None:
    """Checks every limit and records the send in one step, before anything is sent.
    `returning`: the phone or email already signs in to an account. Those still get
    codes past the overall cap, so a flood of new numbers can't lock everyone out."""
    now = now or datetime.now(timezone.utc)
    if db.get_bind().dialect.name == "postgresql":
        db.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": _CODE_LOCK})
    check_rate_limits(db, channel, target, device_id, ip, now)

    def sent_since(moment: datetime) -> int:
        return db.scalar(select(func.count()).select_from(CodeRequest).where(
            CodeRequest.channel == channel, CodeRequest.created_at >= moment)) or 0

    if not returning and (sent_since(now - timedelta(hours=1)) >= per_hour
                          or sent_since(now - timedelta(days=1)) >= per_day):
        log.warning("Global %s code limit reached", channel)
        raise CodeProblem(429, "Aisle is sending a lot of codes right now. Try again a little later.")
    db.add(CodeRequest(channel=channel, target=target_key(channel, target), device_id=device_id, ip=ip,
                       created_at=now))
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


_WORDMARK_ID = "aisle-wordmark"
_WORDMARK_PNG = base64.b64encode((Path(__file__).parent / "aisle-wordmark.png").read_bytes()).decode()


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
            # Inline, so the wordmark shows without "load images" and without hosting it.
            "attachments": [{"filename": "aisle.png", "content": _WORDMARK_PNG, "content_id": _WORDMARK_ID}],
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

    def send_text(self, email: str, subject: str, text: str) -> None:
        """A plain email to Aisle itself, like a report of a shared list to support."""
        try:
            response = self._client.post(
                "https://api.resend.com/emails",
                json={"from": self._sender, "to": [email], "subject": subject, "text": text},
                headers={"Authorization": f"Bearer {self._api_key}"},
            )
        except httpx.HTTPError as error:
            raise ConnectionError("Resend unreachable") from error
        if response.status_code not in (200, 201):
            log.warning("Resend send failed: HTTP %s", response.status_code)
            raise ConnectionError("Resend send failed")


# The app's accent ink (lavender, pink, peach), one stop per letter, so the word reads as
# a gradient even in Gmail, which drops background-clip text.
_GRADIENT_WORD = (("c", "#9A6BD6"), ("o", "#C66EAF"), ("d", "#E17C88"), ("e", "#EC9560"))


def _email_html(code: str) -> str:
    """Aisle-branded code email, styled like the app's "Check your email" screen: the bare
    wordmark on the warm glow background, a big Geist headline with its last word in the
    accent ink, and the code in six white boxes like the ones it gets typed into.

    Tables and inline styles so Gmail, Outlook and Apple Mail all agree. Gradients fall
    back to solid colours, and the digit boxes are inline spans with nothing between
    them, so copying the code still gives six plain digits."""
    font = "'Geist',-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"
    word = "".join(f'<span style="color:{color}">{letter}</span>' for letter, color in _GRADIENT_WORD)
    box = ("display:inline-block;width:54px;height:64px;line-height:64px;margin-right:9px;"
           "background:#FFFFFF;border:1px solid #EFE6EC;border-radius:16px;text-align:center;"
           "font-size:28px;font-weight:600;color:#1F1B24;box-shadow:0 6px 16px rgba(220,111,156,0.10)")
    digits = "".join(
        f'<span class="aisle-digit" style="{box}{";margin-right:0" if i == len(code) - 1 else ""}">{d}</span>'
        for i, d in enumerate(code)
    )
    return f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light only"><meta name="supported-color-schemes" content="light only">
<title>{code} is your Aisle code</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&display=swap');
@media (max-width:480px) {{
  .aisle-page {{ padding:16px 10px 28px !important; }}
  .aisle-pad {{ padding-left:24px !important; padding-right:24px !important; }}
  .aisle-title {{ font-size:32px !important; line-height:36px !important; }}
  .aisle-digit {{ width:44px !important; height:56px !important; line-height:56px !important; margin-right:6px !important; font-size:24px !important; border-radius:14px !important; }}
}}
@media (max-width:360px) {{
  .aisle-digit {{ width:38px !important; height:50px !important; line-height:50px !important; margin-right:5px !important; font-size:22px !important; }}
}}
</style>
</head>
<body style="margin:0;padding:0;background:#F3F4F1">
<div style="display:none;max-height:0;overflow:hidden;opacity:0">{code} &middot; Enter it in Aisle to sign in. It works for 10 minutes.</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F3F4F1">
<tr><td class="aisle-page" align="center" style="padding:40px 16px 36px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:480px;border-radius:32px;overflow:hidden;font-family:{font};color:#1F1B24;background-color:#FCF3F1;background-image:radial-gradient(circle at 100% 0%,rgba(244,143,184,0.30) 0%,rgba(244,143,184,0) 55%),radial-gradient(circle at 0% 100%,rgba(255,216,114,0.30) 0%,rgba(255,216,114,0) 55%),linear-gradient(160deg,#F6EEFD 0%,#FDEDF3 40%,#FFF2E7 75%,#FFF8E3 100%)">
<tr><td class="aisle-pad" style="padding:36px 40px 0">
<img src="cid:{_WORDMARK_ID}" width="96" height="26" alt="aisle" style="display:block;border:0;width:96px;height:26px">
</td></tr>
<tr><td class="aisle-pad" style="padding:56px 40px 0">
<p class="aisle-title" style="margin:0;font-size:38px;line-height:42px;font-weight:700;letter-spacing:-1.2px;color:#1F1B24">Here's your {word}</p>
<p style="margin:14px 0 0;font-size:17px;line-height:25px;color:#4E544F">Enter it in Aisle to finish signing in.</p>
</td></tr>
<tr><td class="aisle-pad" style="padding:32px 40px 0;white-space:nowrap">{digits}</td></tr>
<tr><td class="aisle-pad" style="padding:16px 40px 0">
<p style="margin:0;font-size:14px;line-height:20px;font-weight:500;color:#1F1B24">Works for 10 minutes</p>
</td></tr>
<tr><td class="aisle-pad" style="padding:48px 40px 36px">
<p style="margin:0;font-size:13px;line-height:19px;color:#6E6872">Didn't ask for this? You can ignore this email. Nobody can sign in without the code, and we'll never ask you to share it.</p>
</td></tr>
</table>
<p style="margin:22px 0 0;font-family:{font};font-size:12px;line-height:18px;color:#8A8F8B">aisle &middot; find anything inside any store</p>
</td></tr>
</table>
</body></html>"""


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
    # Count the try in the same statement that checks the limit, so parallel guesses
    # can't all slip in under it.
    counted = db.execute(
        update(EmailCode).where(EmailCode.id == current.id, EmailCode.attempts < MAX_CODE_ATTEMPTS)
        .values(attempts=EmailCode.attempts + 1).returning(EmailCode.id)
    ).scalar()
    db.commit()
    if counted is None:
        raise CodeProblem(429, "Too many wrong tries. Ask for a new code.")
    if not hmac.compare_digest(current.code_hash, _hash_code(email, code)):
        return False
    # And use it up the same way, so it signs in once.
    used = db.execute(
        update(EmailCode).where(EmailCode.id == current.id, EmailCode.consumed_at.is_(None))
        .values(consumed_at=now).returning(EmailCode.id)
    ).scalar()
    db.commit()
    return used is not None
