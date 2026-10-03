"""Create retailers and stores for Milestone 1."""
from alembic import op
import sqlalchemy as sa

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "retailers",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("name", sa.String(200), nullable=False),
        sa.UniqueConstraint("name"),
    )
    op.create_table(
        "stores",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("retailer_id", sa.Integer(), sa.ForeignKey("retailers.id"), nullable=False),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("address", sa.String(500), nullable=False),
        sa.Column("latitude", sa.Float(), nullable=False),
        sa.Column("longitude", sa.Float(), nullable=False),
        sa.Column("external_place_id", sa.String(255), nullable=True),
        sa.Column("store_number", sa.String(50), nullable=True),
        sa.CheckConstraint("latitude >= -90 AND latitude <= 90", name="valid_latitude"),
        sa.CheckConstraint("longitude >= -180 AND longitude <= 180", name="valid_longitude"),
    )
    op.create_index("ix_stores_retailer_id", "stores", ["retailer_id"])


def downgrade():
    op.drop_index("ix_stores_retailer_id", table_name="stores")
    op.drop_table("stores")
    op.drop_table("retailers")
