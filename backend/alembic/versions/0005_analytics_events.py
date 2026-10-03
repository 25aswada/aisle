"""Milestone 7: basic analytics events."""
from alembic import op
import sqlalchemy as sa

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "analytics_events",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("name", sa.String(40), nullable=False),
        sa.Column("device_id", sa.String(64), nullable=True),
        sa.Column("properties", sa.JSON(), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_analytics_events_name", "analytics_events", ["name"])
    op.create_index("ix_analytics_events_received_at", "analytics_events", ["received_at"])


def downgrade():
    op.drop_index("ix_analytics_events_received_at", table_name="analytics_events")
    op.drop_index("ix_analytics_events_name", table_name="analytics_events")
    op.drop_table("analytics_events")
