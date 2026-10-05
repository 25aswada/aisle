"""Accounts: sign in with Apple, Google, an SMS code or an email code, then manage the account.

Every sign-in returns a session token; the app sends it as "Authorization: Bearer ..."
to /me and /auth/signout. The app requires an account; in the API, photo search,
follow-ups, reports and sharing need one, and everything else also works signed out
(with a smaller daily allowance of AI answers).
"""
import hashlib
import logging
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..auth.accounts import (
    PhoneTaken, TooManyNewAccounts, add_phone, create_session, delete_user, first_use_of_nonce, has_account, revoke,
    sign_in, unlink_identity, user_for_token,
)
from ..auth.apple_revocation import revoke_for_deletion
from ..auth.apple_tokens import AppleTokens, from_settings
from ..auth.codes import (
    RESEND_COOLDOWN, CodeProblem, EmailSender, PhoneVerifier, ResendEmailSender, TwilioPhoneVerifier,
    check_email_code, check_sms_country, issue_email_code, normalize_email, normalize_phone,
    reserve_code_request,
)
from ..auth.identity import IdentityVerifier, InvalidToken, JWKSIdentityVerifier
from ..limits import client_ip, rate_limit
from ..plus.access import Caller, require_signed_in
from ..config import get_settings
from ..database import get_db
from ..models import AuthSession, User, UserIdentity
from ..schemas import (
    AccountDeletion, AppleNotification, AppleSignIn, AuthOut, CodeSent, EmailStart, EmailVerify, GoogleSignIn,
    PhoneStart, PhoneVerify, ProfileUpdate, UserOut,
)

log = logging.getLogger(__name__)
router = APIRouter()
Database = Annotated[Session, Depends(get_db)]
DeviceID = Annotated[str | None, Header(alias="X-Aisle-Device", max_length=64)]

UNAVAILABLE = "Aisle can't send codes right now. Try another way to sign in."
WRONG_CODE = "That code didn't work. Check it and try again."


# MARK: - Providers (overridden in tests)

def get_phone_verifier() -> PhoneVerifier | None:
    s = get_settings()
    if not (s.twilio_account_sid and s.twilio_auth_token and s.twilio_verify_service_sid):
        return None
    return TwilioPhoneVerifier(s.twilio_account_sid, s.twilio_auth_token, s.twilio_verify_service_sid)


def get_email_sender() -> EmailSender | None:
    s = get_settings()
    return ResendEmailSender(s.resend_api_key, s.aisle_email_from) if s.resend_api_key else None


def get_apple_tokens() -> AppleTokens | None:
    return from_settings(get_settings())


def get_identity_verifier() -> IdentityVerifier:
    s = get_settings()
    return JWKSIdentityVerifier(s.apple_bundle_id, s.google_ios_client_id)


Phones = Annotated[PhoneVerifier | None, Depends(get_phone_verifier)]
Emails = Annotated[EmailSender | None, Depends(get_email_sender)]
Identities = Annotated[IdentityVerifier, Depends(get_identity_verifier)]
AppleTokensDep = Annotated[AppleTokens | None, Depends(get_apple_tokens)]


def current_session(
    db: Database, authorization: Annotated[str | None, Header()] = None,
) -> tuple[User, AuthSession]:
    scheme, _, token = (authorization or "").partition(" ")
    found = user_for_token(db, token.strip()) if scheme.lower() == "bearer" and token.strip() else None
    if found is None:
        raise HTTPException(status_code=401, detail="Sign in again.", headers={"WWW-Authenticate": "Bearer"})
    return found


SignedIn = Annotated[tuple[User, AuthSession], Depends(current_session)]


def optional_user(db: Database, authorization: Annotated[str | None, Header()] = None) -> User | None:
    """The signed-in user, or None. Never fails: these routes work signed out too."""
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        return None
    found = user_for_token(db, token.strip())
    return found[0] if found else None


def get_caller(
    request: Request, user: Annotated[User | None, Depends(optional_user)], device_id: DeviceID = None,
) -> Caller:
    return Caller(user=user, device_id=device_id, ip=client_ip(request))


CallerDep = Annotated[Caller, Depends(get_caller)]


def signed_in_for(what: str):
    """A route dependency: 401 "Sign in to use <what>." when signed out. Dependencies run
    before the body is checked, so a photo sent without an account is never decoded."""
    def check(caller: CallerDep) -> None:
        require_signed_in(caller, what)
    return Depends(check)


def user_out(user: User) -> UserOut:
    return UserOut(
        id=user.id, plus_token=user.plus_token, first_name=user.first_name, email=user.email, phone=user.phone,
        wants_tips=user.wants_tips, providers=sorted({i.provider for i in user.identities}),
    )


def signed_in(db: Session, user: User, is_new: bool, device_id: str | None) -> AuthOut:
    return AuthOut(token=create_session(db, user, device_id), user=user_out(user), is_new=is_new)


def problem(error: CodeProblem) -> HTTPException:
    return HTTPException(status_code=error.status, detail=error.message)


def reserve(db: Session, channel: str, target: str, device_id: str | None, request: Request) -> None:
    s = get_settings()
    reserve_code_request(db, channel, target, device_id, client_ip(request),
                         per_hour=s.aisle_codes_per_hour, per_day=s.aisle_codes_per_day,
                         returning=has_account(db, channel, target))


def limit_sign_ins(db: Session, request: Request) -> None:
    """Sign-ins and code checks per network per hour, so codes and tokens can't be tried
    at speed."""
    rate_limit(db, f"ip:{client_ip(request)}", "sign_in", get_settings().aisle_sign_ins_per_hour,
               "That's a lot of sign-in attempts. Try again in a little while.")


def account_for(db: Session, provider: str, subject: str, **details) -> tuple[User, bool]:
    try:
        return sign_in(db, provider, subject, **details)
    except TooManyNewAccounts:
        raise HTTPException(status_code=429, detail="This network has made a lot of new accounts today. Try again tomorrow.")


def check_nonce_unused(db: Session, provider: str, nonce: str, problem_detail: str) -> None:
    if not first_use_of_nonce(db, provider, nonce):
        raise HTTPException(status_code=401, detail=problem_detail)


# MARK: - SMS codes

@router.post("/auth/phone/start", response_model=CodeSent)
def phone_start(body: PhoneStart, db: Database, phones: Phones, request: Request, device_id: DeviceID = None):
    if phones is None:
        raise HTTPException(status_code=503, detail=UNAVAILABLE)
    try:
        phone = normalize_phone(body.phone)
        check_sms_country(phone, get_settings().sms_country_codes)
        reserve(db, "sms", phone, device_id, request)
        phones.send(phone)
    except CodeProblem as error:
        raise problem(error)
    except ConnectionError:
        raise HTTPException(status_code=503, detail=UNAVAILABLE)
    return CodeSent(sent_to=mask_phone(phone), retry_after=int(RESEND_COOLDOWN.total_seconds()))


@router.post("/auth/phone/verify", response_model=AuthOut)
def phone_verify(body: PhoneVerify, db: Database, phones: Phones, request: Request, device_id: DeviceID = None):
    if phones is None:
        raise HTTPException(status_code=503, detail=UNAVAILABLE)
    limit_sign_ins(db, request)
    try:
        phone = normalize_phone(body.phone)
        approved = phones.check(phone, body.code)
    except CodeProblem as error:
        raise problem(error)
    except ConnectionError:
        raise HTTPException(status_code=503, detail=UNAVAILABLE)
    if not approved:
        raise HTTPException(status_code=400, detail=WRONG_CODE)
    user, is_new = account_for(db, "phone", phone, phone=phone)
    return signed_in(db, user, is_new, device_id)


def mask_phone(phone: str) -> str:
    return f"{phone[:-4][:2]} •••• {phone[-4:]}" if phone.startswith("+1") else f"•••• {phone[-4:]}"


# MARK: - Email codes

@router.post("/auth/email/start", response_model=CodeSent)
def email_start(body: EmailStart, db: Database, emails: Emails, request: Request, device_id: DeviceID = None):
    if emails is None:
        raise HTTPException(status_code=503, detail=UNAVAILABLE)
    try:
        email = normalize_email(body.email)
        reserve(db, "email", email, device_id, request)
        issue_email_code(db, email, emails)
    except CodeProblem as error:
        raise problem(error)
    except ConnectionError:
        raise HTTPException(status_code=503, detail=UNAVAILABLE)
    return CodeSent(sent_to=email, retry_after=int(RESEND_COOLDOWN.total_seconds()))


@router.post("/auth/email/verify", response_model=AuthOut)
def email_verify(body: EmailVerify, db: Database, request: Request, device_id: DeviceID = None):
    limit_sign_ins(db, request)
    try:
        email = normalize_email(body.email)
        approved = check_email_code(db, email, body.code)
    except CodeProblem as error:
        raise problem(error)
    if not approved:
        raise HTTPException(status_code=400, detail=WRONG_CODE)
    # The code proved they own the address.
    user, is_new = account_for(db, "email", email, email=email, email_verified=True)
    return signed_in(db, user, is_new, device_id)


# MARK: - Apple and Google

APPLE_FAILED = "Apple sign-in didn't go through. Try again."
GOOGLE_FAILED = "Google sign-in didn't go through. Try again."


@router.post("/auth/apple", response_model=AuthOut)
def apple(body: AppleSignIn, db: Database, identities: Identities, apple_tokens: AppleTokensDep,
          request: Request, device_id: DeviceID = None):
    limit_sign_ins(db, request)
    try:
        who = identities.apple(body.identity_token, body.nonce)
    except InvalidToken:
        raise HTTPException(status_code=401, detail=APPLE_FAILED)
    except ConnectionError:
        raise HTTPException(status_code=503, detail="Couldn't reach Apple. Try again in a moment.")
    # The token carries the nonce's hash; each one signs in once.
    check_nonce_unused(db, "apple", hashlib.sha256(body.nonce.encode()).hexdigest(), APPLE_FAILED)
    user, is_new = account_for(db, "apple", who.subject, email=who.email, email_verified=who.email_verified,
                               given_name=body.first_name)
    if apple_tokens is not None and body.authorization_code:
        # Kept so deleting the account can revoke this Apple sign-in. Best effort: a
        # failure here never stops the sign-in.
        refresh = apple_tokens.refresh_token(body.authorization_code)
        identity = next((i for i in user.identities if i.provider == "apple" and i.subject == who.subject), None)
        if refresh and identity is not None:
            identity.apple_refresh_token = refresh
            db.commit()
    return signed_in(db, user, is_new, device_id)


@router.post("/auth/google", response_model=AuthOut)
def google(body: GoogleSignIn, db: Database, identities: Identities, request: Request, device_id: DeviceID = None):
    limit_sign_ins(db, request)
    try:
        who = identities.google(body.id_token, body.nonce)
    except InvalidToken:
        raise HTTPException(status_code=401, detail=GOOGLE_FAILED)
    except ConnectionError:
        raise HTTPException(status_code=503, detail="Couldn't reach Google. Try again in a moment.")
    check_nonce_unused(db, "google", body.nonce, GOOGLE_FAILED)
    user, is_new = account_for(db, "google", who.subject, email=who.email, email_verified=who.email_verified,
                               given_name=who.given_name)
    return signed_in(db, user, is_new, device_id)


# MARK: - The signed-in account

@router.get("/me", response_model=UserOut)
def me(session: SignedIn):
    return user_out(session[0])


@router.patch("/me", response_model=UserOut)
def update_me(body: ProfileUpdate, db: Database, session: SignedIn):
    user = session[0]
    if body.first_name is not None:
        user.first_name = body.first_name[:40]
    if body.wants_tips is not None:
        user.wants_tips = body.wants_tips
    db.commit()
    db.refresh(user)
    return user_out(user)


# Adding a phone number to the signed-in account, so it signs in here too.

PHONE_TAKEN = ("That number already has its own Aisle account. Sign in with it and delete that "
               "account in You, or use a different number.")


@router.post("/me/phone/start", response_model=CodeSent)
def add_phone_start(body: PhoneStart, db: Database, phones: Phones, request: Request, session: SignedIn,
                    device_id: DeviceID = None):
    if phones is None:
        raise HTTPException(status_code=503, detail="Aisle can't send texts right now. Try again later.")
    try:
        phone = normalize_phone(body.phone)
        if session[0].phone == phone:
            raise CodeProblem(400, "That number is already on your account.")
        check_sms_country(phone, get_settings().sms_country_codes)
        reserve(db, "sms", phone, device_id, request)
        phones.send(phone)
    except CodeProblem as error:
        raise problem(error)
    except ConnectionError:
        raise HTTPException(status_code=503, detail="Aisle can't send texts right now. Try again later.")
    return CodeSent(sent_to=mask_phone(phone), retry_after=int(RESEND_COOLDOWN.total_seconds()))


@router.post("/me/phone/verify", response_model=UserOut)
def add_phone_verify(body: PhoneVerify, db: Database, phones: Phones, session: SignedIn, request: Request):
    if phones is None:
        raise HTTPException(status_code=503, detail="Aisle can't check codes right now. Try again later.")
    limit_sign_ins(db, request)
    try:
        phone = normalize_phone(body.phone)
        approved = phones.check(phone, body.code)
    except CodeProblem as error:
        raise problem(error)
    except ConnectionError:
        raise HTTPException(status_code=503, detail="Aisle can't check codes right now. Try again later.")
    if not approved:
        raise HTTPException(status_code=400, detail=WRONG_CODE)
    # Only now, with the number proven, say whether another account has it.
    try:
        return user_out(add_phone(db, session[0], phone))
    except PhoneTaken:
        raise HTTPException(status_code=409, detail=PHONE_TAKEN)


@router.delete("/me", status_code=204)
def delete_me(db: Database, session: SignedIn, apple_tokens: AppleTokensDep, body: AccountDeletion | None = None):
    # With an Apple sign-in, the app sends a fresh code from Apple so it can be revoked.
    revoke_for_deletion(db, session[0], body.authorization_code if body else None, apple_tokens)
    delete_user(db, session[0])
    return Response(status_code=204)


@router.post("/auth/apple/notifications")
def apple_notification(body: AppleNotification, db: Database, identities: Identities):
    """Sign in with Apple's server-to-server notifications. Set this URL in Certificates,
    Identifiers & Profiles > the App ID > Sign in with Apple > Server-to-Server
    Notification Endpoint.

    consent-revoked (the person stopped using Apple with Aisle) unlinks that Apple ID and
    signs the account out everywhere. account-delete (the Apple ID itself is gone) does the
    same, and deletes the account when Apple was its only way in, since nobody can sign in
    to it again."""
    try:
        event = identities.apple_event(body.payload)
    except InvalidToken as error:
        log.warning("Rejected a Sign in with Apple notification: %s", error)
        raise HTTPException(status_code=400, detail="Not a genuine Sign in with Apple notification.")
    except ConnectionError:
        raise HTTPException(status_code=503, detail="Couldn't reach Apple. Try again in a moment.")
    if event.type not in ("consent-revoked", "account-delete"):
        return {"ok": True}  # email-disabled and email-enabled change nothing here.
    if event.id and not first_use_of_nonce(db, "apple-event", event.id):
        return {"ok": True}  # Already handled.
    identity = db.scalar(select(UserIdentity).where(
        UserIdentity.provider == "apple", UserIdentity.subject == event.subject))
    if identity is None:
        return {"ok": True}
    if event.type == "account-delete" and all(i.provider == "apple" for i in identity.user.identities):
        delete_user(db, identity.user)  # Apple has already ended its tokens.
    else:
        unlink_identity(db, identity)
    return {"ok": True}


@router.post("/auth/signout", status_code=204)
def sign_out(db: Database, session: SignedIn):
    revoke(db, session[1])
    return Response(status_code=204)
