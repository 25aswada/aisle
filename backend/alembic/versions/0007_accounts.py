"""Accounts: users, their sign-in identities, sessions, email codes and code rate limits."""
from alembic import op
import sqlalchemy as sa

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "users",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("first_name", sa.String(40), nullable=False, server_default=""),
        sa.Column("email", sa.String(320), nullable=True),
        sa.Column("phone", sa.String(20), nullable=True),
        sa.Column("wants_tips", sa.Boolean, nullable=False, server_default=sa.false()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_users_email", "users", ["email"])
    op.create_table(
        "user_identities",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("provider", sa.String(10), nullable=False),
        sa.Column("subject", sa.String(320), nullable=False),
        sa.Column("email", sa.String(320), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("provider", "subject", name="uq_identity_provider_subject"),
    )
    op.create_index("ix_user_identities_user_id", "user_identities", ["user_id"])
    op.create_table(
        "auth_sessions",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("token_hash", sa.String(64), nullable=False, unique=True),
        sa.Column("device_id", sa.String(64), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_auth_sessions_user_id", "auth_sessions", ["user_id"])
    op.create_table(
        "email_codes",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("email", sa.String(320), nullable=False),
        sa.Column("code_hash", sa.String(64), nullable=False),
        sa.Column("attempts", sa.Integer, nullable=False, server_default="0"),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_email_codes_email", "email_codes", ["email"])
    op.create_table(
        "code_requests",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("channel", sa.String(10), nullable=False),
        sa.Column("target", sa.String(320), nullable=False),
        sa.Column("device_id", sa.String(64), nullable=True),
        sa.Column("ip", sa.String(45), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_code_requests_target", "code_requests", ["target"])
    op.create_index("ix_code_requests_device_id", "code_requests", ["device_id"])
    op.create_index("ix_code_requests_ip", "code_requests", ["ip"])
    op.create_index("ix_code_requests_created_at", "code_requests", ["created_at"])


def downgrade():
    op.drop_table("code_requests")
    op.drop_table("email_codes")
    op.drop_table("auth_sessions")
    op.drop_table("user_identities")
    op.drop_table("users")
