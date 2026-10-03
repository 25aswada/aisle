from functools import lru_cache

from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session

from .config import get_settings


def make_engine(url: str):
    # Accept common deployment URLs while using the psycopg 3 driver.
    if url.startswith(("postgres://", "postgresql://")):
        url = "postgresql+psycopg://" + url.split("://", 1)[1]
    engine = create_engine(
        url,
        pool_pre_ping=True,
        connect_args={"check_same_thread": False} if url.startswith("sqlite") else {},
    )
    if engine.dialect.name == "sqlite":
        @event.listens_for(engine, "connect")
        def enable_foreign_keys(connection, _):
            connection.execute("PRAGMA foreign_keys=ON")
    return engine


@lru_cache
def get_engine():
    return make_engine(get_settings().database_url)


def get_db():
    with Session(get_engine()) as session:
        yield session
