from alembic import command
from sqlalchemy import func, inspect, select
from sqlalchemy.orm import Session

from backend.app.models import Base, Retailer, Store
from backend.app.seed import seed_stores
from conftest import migration_config


def test_seed_is_idempotent_and_covers_retailers(engine):
    with Session(engine) as session:
        seed_stores(session)
        original_ids = list(session.scalars(select(Store.id).order_by(Store.id)))
        seed_stores(session)
        assert list(session.scalars(select(Store.id).order_by(Store.id))) == original_ids
        assert session.scalar(select(func.count()).select_from(Store)) == 6
        assert set(session.scalars(select(Retailer.name))) == {
            "Costco", "Trader Joe's", "Walmart", "Target", "CVS", "Home Depot"
        }
        for name in ("Costco", "Trader Joe's"):
            store = session.scalar(select(Store).join(Store.retailer).where(Retailer.name == name))
            assert 39.8 < store.latitude < 40.2
            assert -75.5 < store.longitude < -75.0
            assert store.external_place_id is None
            assert store.store_number is None


def test_migration_round_trip_and_metadata_agreement(engine):
    from alembic.autogenerate import compare_metadata
    from alembic.migration import MigrationContext

    with engine.connect() as connection:
        assert compare_metadata(MigrationContext.configure(connection), Base.metadata) == []
    config = migration_config(engine.url.render_as_string(hide_password=False))
    command.downgrade(config, "base")
    assert "stores" not in inspect(engine).get_table_names()
    assert "retailers" not in inspect(engine).get_table_names()
    command.upgrade(config, "head")
    assert {"stores", "retailers"} <= set(inspect(engine).get_table_names())
