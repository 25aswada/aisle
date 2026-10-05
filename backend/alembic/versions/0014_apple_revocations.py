"""Apple sign-ins of deleted accounts that still need revoking, retried by cleanup."""
from alembic import op
import sqlalchemy as sa

revision = "0014"
down_revision = "0013"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "apple_revocations",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("refresh_token", sa.String(500), nullable=True),
        sa.Column("authorization_code", sa.String(2000), nullable=True),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("next_attempt_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_apple_revocations_next_attempt_at", "apple_revocations", ["next_attempt_at"])


def downgrade():
    op.drop_index("ix_apple_revocations_next_attempt_at", table_name="apple_revocations")
    op.drop_table("apple_revocations")
