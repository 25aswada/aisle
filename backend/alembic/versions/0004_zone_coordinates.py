"""Milestone 6: zone coordinates and store entrance/checkout anchors."""
from alembic import op
import sqlalchemy as sa

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("store_zones") as batch:
        batch.add_column(sa.Column("x", sa.Float(), nullable=True))
        batch.add_column(sa.Column("y", sa.Float(), nullable=True))
    with op.batch_alter_table("stores") as batch:
        for column in ("entrance_x", "entrance_y", "checkout_x", "checkout_y"):
            batch.add_column(sa.Column(column, sa.Float(), nullable=True))


def downgrade():
    with op.batch_alter_table("stores") as batch:
        for column in ("checkout_y", "checkout_x", "entrance_y", "entrance_x"):
            batch.drop_column(column)
    with op.batch_alter_table("store_zones") as batch:
        batch.drop_column("y")
        batch.drop_column("x")
