"""Apple and Google sign-ins remember the nonces they've used, so an ID token can't be replayed."""
from alembic import op
import sqlalchemy as sa

revision = "0013"
down_revision = "0012"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "used_sign_in_nonces",
        sa.Column("nonce_hash", sa.String(64), primary_key=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_used_sign_in_nonces_created_at", "used_sign_in_nonces", ["created_at"])


def downgrade():
    op.drop_index("ix_used_sign_in_nonces_created_at", table_name="used_sign_in_nonces")
    op.drop_table("used_sign_in_nonces")
