"""Accounts: sign in with Apple, Google, an SMS code or an email code, then manage the account.

Every sign-in returns a session token; the app sends it as "Authorization: Bearer ..."
to /me and /auth/signout. The app requires an account; in the API, photo search,
follow-ups and sharing need one, and everything else also works signed out.
"""
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response
from sqlalchemy.orm import Session

from ..auth.accounts import PhoneTaken, add_phone, create_session, delete_user, revoke, sign_in, user_for_token
from ..auth.apple_tokens import AppleTokens, AppleTokenService
from ..auth.codes import (
    RESEND_COOLDOWN, CodeProblem, EmailSender, PhoneVerifier, ResendEmailSender, TwilioPhoneVerifier,
    check_email_code, check_sms_country, issue_email_code, normalize_email, normalize_phone,
    reserve_code_request,
)
from ..auth.identity import IdentityVerifier, InvalidToken, JWKSIdentityVerifier
from ..limits import client_ip
from ..plus.access import Caller
from ..config import get_settings
from ..database import get_db
from ..models import AuthSession, User
from ..schemas import (
    AppleSignIn, AuthOut, CodeSent, EmailStart, EmailVerify, GoogleSignIn, PhoneStart, PhoneVerify,
    ProfileUpdate, UserOut,
)

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
    s = get_settings()
    if not (s.apple_team_id and s.apple_signin_key_id and s.apple_signin_private_key):
        return None
    return AppleTokenService(s.apple_bundle_id, s.apple_team_id, s.apple_signin_key_id, s.apple_signin_private_key)


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
                         per_hour=s.aisle_codes_per_hour, per_day=s.aisle_codes_per_day)


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
def phone_verify(body: PhoneVerify, db: Database, phones: Phones, device_id: DeviceID = None):
    if phones is None:
        raise HTTPException(status_code=503, detail=UNAVAILABLE)
    try:
        phone = normalize_phone(body.phone)
        approved = phones.check(phone, body.code)
    except CodeProblem as error:
        raise problem(error)
    except ConnectionError:
        raise HTTPException(status_code=503, detail=UNAVAILABLE)
    if not approved:
        raise HTTPException(status_code=400, detail=WRONG_CODE)
    user, is_new = sign_in(db, "phone", phone, phone=phone)
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
def email_verify(body: EmailVerify, db: Database, device_id: DeviceID = None):
    try:
        email = normalize_email(body.email)
        approved = check_email_code(db, email, body.code)
    except CodeProblem as error:
        raise problem(error)
    if not approved:
        raise HTTPException(status_code=400, detail=WRONG_CODE)
    # The code proved they own the address.
    user, is_new = sign_in(db, "email", email, email=email, email_verified=True)
    return signed_in(db, user, is_new, device_id)


# MARK: - Apple and Google

@router.post("/auth/apple", response_model=AuthOut)
def apple(body: AppleSignIn, db: Database, identities: Identities, apple_tokens: AppleTokensDep,
          device_id: DeviceID = None):
    try:
        who = identities.apple(body.identity_token, body.nonce)
    except InvalidToken:
        raise HTTPException(status_code=401, detail="Apple sign-in didn't go through. Try again.")
    except ConnectionError:
        raise HTTPException(status_code=503, detail="Couldn't reach Apple. Try again in a moment.")
    user, is_new = sign_in(db, "apple", who.subject, email=who.email, email_verified=who.email_verified,
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
def google(body: GoogleSignIn, db: Database, identities: Identities, device_id: DeviceID = None):
    try:
        who = identities.google(body.id_token, body.nonce)
    except InvalidToken:
        raise HTTPException(status_code=401, detail="Google sign-in didn't go through. Try again.")
    except ConnectionError:
        raise HTTPException(status_code=503, detail="Couldn't reach Google. Try again in a moment.")
    user, is_new = sign_in(db, "google", who.subject, email=who.email, email_verified=who.email_verified,
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
def add_phone_verify(body: PhoneVerify, db: Database, phones: Phones, session: SignedIn):
    if phones is None:
        raise HTTPException(status_code=503, detail="Aisle can't check codes right now. Try again later.")
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
def delete_me(db: Database, session: SignedIn, apple_tokens: AppleTokensDep):
    if apple_tokens is not None:
        for identity in session[0].identities:
            if identity.provider == "apple" and identity.apple_refresh_token:
                apple_tokens.revoke(identity.apple_refresh_token)
    delete_user(db, session[0])
    return Response(status_code=204)


@router.post("/auth/signout", status_code=204)
def sign_out(db: Database, session: SignedIn):
    revoke(db, session[1])
    return Response(status_code=204)
