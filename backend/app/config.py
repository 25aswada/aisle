import os
from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    database_url: str = "postgresql+psycopg://aisle:aisle_local@localhost:5432/aisle"
    # AI provider. Without a key the deterministic catalog fallback answers every query.
    anthropic_api_key: str | None = None
    openai_api_key: str | None = None
    # auto: Anthropic when its key is set, otherwise OpenAI when its key is set.
    aisle_ai_provider: Literal["auto", "anthropic", "openai"] = "auto"
    # Unset means the provider's default model.
    aisle_ai_model: str | None = None
    # catalog_first: the model only handles queries the catalog can't classify.
    # model_first: the model answers first and the catalog is the fallback.
    aisle_ai_strategy: Literal["catalog_first", "model_first"] = "catalog_first"
    aisle_ai_timeout_seconds: float = 8.0
    # Written replies (follow-ups, photos) are longer, so they get more time. A search's
    # explanation comes after its location guess, so both together stay under Heroku's
    # 30-second request limit.
    aisle_ai_reply_timeout_seconds: float = 22.0
    aisle_ai_explain_timeout_seconds: float = 16.0
    # With a key, the model also writes each result's "where to find it" explanation.
    aisle_ai_explain: bool = True
    # logo.dev publishable key (pk_...). Without it stores show letter tiles.
    logo_dev_publishable_key: str | None = None

    # Accounts. Each sign-in method is off until its keys are set.
    # SMS codes: a Twilio Verify service.
    twilio_account_sid: str | None = None
    twilio_auth_token: str | None = None
    twilio_verify_service_sid: str | None = None
    # Email codes: Resend, sending from a verified domain.
    resend_api_key: str | None = None
    aisle_email_from: str = "Aisle <codes@shopaisle.app>"
    # Sign in with Google: the iOS OAuth client ID its ID tokens are issued to.
    google_ios_client_id: str | None = None
    # Sign in with Apple: the app's bundle ID its identity tokens are issued to.
    apple_bundle_id: str = "app.shopaisle.aisle"
    # A Sign in with Apple key (Certificates, Identifiers & Profiles > Keys), so deleting an
    # account can revoke its Apple sign-in, as App Review requires. The private key is the
    # .p8 file's contents.
    apple_team_id: str | None = None
    apple_signin_key_id: str | None = None
    apple_signin_private_key: str | None = None
    # Countries (calling codes, comma separated) that SMS codes can go to. Texts to other
    # countries can cost far more, and are a favorite of SMS-pumping fraud.
    aisle_sms_country_codes: str = "1"
    # All sign-in codes sent, per channel (sms, email), across everyone.
    aisle_codes_per_hour: int = 200
    aisle_codes_per_day: int = 1000

    # Fair use, per account (or per network when signed out), per hour.
    aisle_searches_per_hour: int = 120
    aisle_photos_per_hour: int = 40
    aisle_follow_ups_per_hour: int = 80
    aisle_routes_per_hour: int = 60
    aisle_writes_per_hour: int = 120
    # Store maps are laid out the first time a store is used; this caps how many new ones
    # one network, and everyone together, can cause in a day.
    aisle_new_store_maps_per_ip_per_day: int = 150
    aisle_new_store_maps_per_day: int = 3000

    # Aisle+. The free tier's daily limits (per account, or per device when signed out).
    aisle_free_photo_searches: int = 5
    aisle_free_follow_ups: int = 10
    # Accept purchases from Xcode's local StoreKit testing. Ignored on Heroku.
    aisle_plus_allow_xcode: bool = False
    model_config = SettingsConfigDict(
        env_file=Path(__file__).resolve().parents[1] / ".env", extra="ignore"
    )

    @property
    def on_heroku(self) -> bool:
        """Running as the deployed app (Heroku sets DYNO), not locally or in tests."""
        return bool(os.environ.get("DYNO"))

    @property
    def allow_xcode_purchases(self) -> bool:
        # Xcode's test purchases are self-signed; accepting them in production would let
        # anyone make their own Aisle+.
        return self.aisle_plus_allow_xcode and not self.on_heroku

    @property
    def sms_country_codes(self) -> tuple[str, ...]:
        return tuple(code.strip().lstrip("+") for code in self.aisle_sms_country_codes.split(",") if code.strip())

    @field_validator("database_url")
    @classmethod
    def use_psycopg(cls, url: str) -> str:
        """Heroku's DATABASE_URL is postgres://...; SQLAlchemy and Alembic here use psycopg 3."""
        if url.startswith(("postgres://", "postgresql://")):
            return "postgresql+psycopg://" + url.split("://", 1)[1]
        return url


@lru_cache
def get_settings() -> Settings:
    return Settings()
