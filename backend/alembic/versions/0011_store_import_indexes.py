"""Indexes for a real store directory: nearby search narrows by latitude, and the
OpenStreetMap importer finds stores by their place ID (unique, so a re-import can't
duplicate a store)."""
from alembic import op

revision = "0011"
down_revision = "0010"
branch_labels = None
depends_on = None


def upgrade():
    op.create_index("ix_stores_latitude", "stores", ["latitude"])
    op.create_index("ix_stores_external_place_id", "stores", ["external_place_id"], unique=True)


def downgrade():
    op.drop_index("ix_stores_external_place_id", table_name="stores")
    op.drop_index("ix_stores_latitude", table_name="stores")
