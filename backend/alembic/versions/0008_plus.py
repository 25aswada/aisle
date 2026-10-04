"""Aisle+: verified App Store subscriptions and the free tier's daily usage."""
from alembic import op
import sqlalchemy as sa

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "plus_entitlements",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("original_transaction_id", sa.String(64), nullable=False, unique=True),
        sa.Column("product_id", sa.String(100), nullable=False),
        sa.Column("environment", sa.String(20), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("device_id", sa.String(64), nullable=True),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_plus_entitlements_device_id", "plus_entitlements", ["device_id"])
    op.create_index("ix_plus_entitlements_user_id", "plus_entitlements", ["user_id"])
    op.create_table(
        "usage_counters",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("subject", sa.String(80), nullable=False),
        sa.Column("feature", sa.String(20), nullable=False),
        sa.Column("day", sa.String(10), nullable=False),
        sa.Column("count", sa.Integer, nullable=False, server_default="0"),
        sa.UniqueConstraint("subject", "feature", "day", name="uq_usage_subject_feature_day"),
    )


def downgrade():
    op.drop_table("usage_counters")
    op.drop_table("plus_entitlements")
