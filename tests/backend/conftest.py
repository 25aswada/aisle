from pathlib import Path
import sys

# Keep `pytest` usable from the repo root without installing a package or
# changing files outside backend ownership. Avoid tests/backend shadowing it.
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from backend.app.database import get_db, make_engine
from backend.app.main import app
from backend.app.models import Retailer, Store

def migration_config(url):
    config = Config(str(ROOT / "backend" / "alembic.ini"))
    config.set_main_option("sqlalchemy.url", url)
    return config


@pytest.fixture
def engine(tmp_path):
    url = f"sqlite:///{tmp_path / 'test.db'}"
    command.upgrade(migration_config(url), "head")
    engine = make_engine(url)
    yield engine
    engine.dispose()


@pytest.fixture
def populated_engine(engine):
    with Session(engine) as session:
        retailer = Retailer(name="Trader Joe's")
        session.add(retailer)
        session.flush()
        # Deliberately insert in far-to-near order so ordering cannot pass by ID.
        session.add_all([
            Store(retailer_id=retailer.id, name="Far Store", address="30 Far Rd",
                  latitude=42, longitude=-75),
            Store(retailer_id=retailer.id, name="Middle Store", address="20 Market St",
                  latitude=41, longitude=-75),
            Store(retailer_id=retailer.id, name="Near Store", address="10 Market St",
                  latitude=40, longitude=-75),
        ])
        session.commit()
    return engine


@pytest.fixture
def client(populated_engine):
    def override_db():
        with Session(populated_engine) as session:
            yield session

    app.dependency_overrides[get_db] = override_db
    with TestClient(app) as client:
        yield client
    app.dependency_overrides.clear()
