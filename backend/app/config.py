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
    # Written replies (search explanations, follow-ups) are longer, so they get more time.
    aisle_ai_reply_timeout_seconds: float = 25.0
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

    # Aisle+. The free tier's daily limits (per account, or per device when signed out).
    aisle_free_photo_searches: int = 5
    aisle_free_follow_ups: int = 10
    # Accept purchases from Xcode's local StoreKit testing (never in production).
    aisle_plus_allow_xcode: bool = False
    model_config = SettingsConfigDict(
        env_file=Path(__file__).resolve().parents[1] / ".env", extra="ignore"
    )

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
