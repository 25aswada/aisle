from functools import lru_cache
from pathlib import Path
from typing import Literal

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
    model_config = SettingsConfigDict(
        env_file=Path(__file__).resolve().parents[1] / ".env", extra="ignore"
    )


@lru_cache
def get_settings() -> Settings:
    return Settings()
