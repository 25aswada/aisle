"""Retailer website domain, used for logos."""
from alembic import op
import sqlalchemy as sa

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("retailers") as batch:
        batch.add_column(sa.Column("domain", sa.String(253), nullable=True))


def downgrade():
    with op.batch_alter_table("retailers") as batch:
        batch.drop_column("domain")
