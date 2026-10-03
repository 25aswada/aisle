"""Milestone 4: search events and location observations."""
from alembic import op
import sqlalchemy as sa

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "search_events",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("store_id", sa.Integer(), sa.ForeignKey("stores.id", ondelete="SET NULL"), nullable=True),
        sa.Column("query", sa.String(200), nullable=False),
        sa.Column("item_normalized", sa.String(200), nullable=False),
        sa.Column("concept_id", sa.Integer(),
                  sa.ForeignKey("product_concepts.id", ondelete="SET NULL"), nullable=True),
        sa.Column("category_slug", sa.String(80), nullable=True),
        sa.Column("department", sa.String(120), nullable=True),
        sa.Column("zone_id", sa.Integer(), sa.ForeignKey("store_zones.id", ondelete="SET NULL"), nullable=True),
        sa.Column("source", sa.String(20), nullable=False),
        sa.Column("confidence", sa.String(10), nullable=False),
        sa.Column("device_id", sa.String(64), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_search_events_store_id", "search_events", ["store_id"])
    op.create_index("ix_search_events_created_at", "search_events", ["created_at"])
    op.create_table(
        "location_observations",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("store_id", sa.Integer(), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("search_event_id", sa.String(36),
                  sa.ForeignKey("search_events.id", ondelete="SET NULL"), nullable=True),
        sa.Column("concept_id", sa.Integer(),
                  sa.ForeignKey("product_concepts.id", ondelete="SET NULL"), nullable=True),
        sa.Column("item_normalized", sa.String(200), nullable=False),
        sa.Column("verdict", sa.String(10), nullable=False),
        sa.Column("zone_id", sa.Integer(), sa.ForeignKey("store_zones.id", ondelete="SET NULL"), nullable=True),
        sa.Column("aisle_text", sa.String(40), nullable=True),
        sa.Column("note", sa.String(280), nullable=True),
        sa.Column("device_id", sa.String(64), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_location_observations_store_id", "location_observations", ["store_id"])
    op.create_index("ix_location_observations_concept_id", "location_observations", ["concept_id"])
    op.create_index("ix_location_observations_item_normalized", "location_observations", ["item_normalized"])


def downgrade():
    op.drop_table("location_observations")
    op.drop_index("ix_search_events_created_at", table_name="search_events")
    op.drop_index("ix_search_events_store_id", table_name="search_events")
    op.drop_table("search_events")
