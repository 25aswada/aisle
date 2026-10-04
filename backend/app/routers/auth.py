"""Accounts: sign in with Apple, Google, an SMS code or an email code, then manage the account.

Every sign-in returns a session token; the app sends it as "Authorization: Bearer ..."
to /me and /auth/signout. Accounts stay optional: nothing else in the API needs one.
"""
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response
from sqlalchemy.orm import Session

from ..auth.accounts import create_session, delete_user, revoke, sign_in, user_for_token
from ..auth.codes import (
    RESEND_COOLDOWN, CodeProblem, EmailSender, PhoneVerifier, ResendEmailSender, TwilioPhoneVerifier,
    check_email_code, check_rate_limits, issue_email_code, normalize_email, normalize_phone,
    record_code_request,
)
from ..auth.identity import IdentityVerifier, InvalidToken, JWKSIdentityVerifier
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


def get_identity_verifier() -> IdentityVerifier:
    s = get_settings()
    return JWKSIdentityVerifier(s.apple_bundle_id, s.google_ios_client_id)


Phones = Annotated[PhoneVerifier | None, Depends(get_phone_verifier)]
Emails = Annotated[EmailSender | None, Depends(get_email_sender)]
Identities = Annotated[IdentityVerifier, Depends(get_identity_verifier)]


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
        id=user.id, first_name=user.first_name, email=user.email, phone=user.phone,
        wants_tips=user.wants_tips, providers=sorted({i.provider for i in user.identities}),
    )


def signed_in(db: Session, user: User, is_new: bool, device_id: str | None) -> AuthOut:
    return AuthOut(token=create_session(db, user, device_id), user=user_out(user), is_new=is_new)


def problem(error: CodeProblem) -> HTTPException:
    return HTTPException(status_code=error.status, detail=error.message)


def client_ip(request: Request) -> str | None:
    return request.client.host if request.client else None


# MARK: - SMS codes

@router.post("/auth/phone/start", response_model=CodeSent)
def phone_start(body: PhoneStart, db: Database, phones: Phones, request: Request, device_id: DeviceID = None):
    if phones is None:
        raise HTTPException(status_code=503, detail=UNAVAILABLE)
    try:
        phone = normalize_phone(body.phone)
        check_rate_limits(db, "sms", phone, device_id, client_ip(request))
        phones.send(phone)
    except CodeProblem as error:
        raise problem(error)
    except ConnectionError:
        raise HTTPException(status_code=503, detail=UNAVAILABLE)
    record_code_request(db, "sms", phone, device_id, client_ip(request))
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
        check_rate_limits(db, "email", email, device_id, client_ip(request))
        issue_email_code(db, email, emails)
    except CodeProblem as error:
        raise problem(error)
    except ConnectionError:
        raise HTTPException(status_code=503, detail=UNAVAILABLE)
    record_code_request(db, "email", email, device_id, client_ip(request))
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
def apple(body: AppleSignIn, db: Database, identities: Identities, device_id: DeviceID = None):
    try:
        who = identities.apple(body.identity_token, body.nonce)
    except InvalidToken:
        raise HTTPException(status_code=401, detail="Apple sign-in didn't go through. Try again.")
    except ConnectionError:
        raise HTTPException(status_code=503, detail="Couldn't reach Apple. Try again in a moment.")
    user, is_new = sign_in(db, "apple", who.subject, email=who.email, email_verified=who.email_verified,
                           given_name=body.first_name)
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


@router.delete("/me", status_code=204)
def delete_me(db: Database, session: SignedIn):
    delete_user(db, session[0])
    return Response(status_code=204)


@router.post("/auth/signout", status_code=204)
def sign_out(db: Database, session: SignedIn):
    revoke(db, session[1])
    return Response(status_code=204)
