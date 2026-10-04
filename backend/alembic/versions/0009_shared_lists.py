"""Shared family lists: lists on the server, their members and items."""
from alembic import op
import sqlalchemy as sa

revision = "0009"
down_revision = "0008"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "shared_lists",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("owner_id", sa.Integer, sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(60), nullable=False),
        sa.Column("invite_code", sa.String(12), nullable=False, unique=True),
        sa.Column("version", sa.Integer, nullable=False, server_default="1"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_shared_lists_owner_id", "shared_lists", ["owner_id"])
    op.create_table(
        "shared_list_members",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("list_id", sa.String(36), sa.ForeignKey("shared_lists.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("joined_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("list_id", "user_id", name="uq_shared_list_member"),
    )
    op.create_index("ix_shared_list_members_list_id", "shared_list_members", ["list_id"])
    op.create_index("ix_shared_list_members_user_id", "shared_list_members", ["user_id"])
    op.create_table(
        "shared_list_items",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("list_id", sa.String(36), sa.ForeignKey("shared_lists.id", ondelete="CASCADE"), nullable=False),
        sa.Column("text", sa.String(200), nullable=False),
        sa.Column("quantity", sa.String(40), nullable=True),
        sa.Column("category_name", sa.String(80), nullable=True),
        sa.Column("is_done", sa.Boolean, nullable=False, server_default=sa.false()),
        sa.Column("position", sa.Float, nullable=False, server_default="0"),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_shared_list_items_list_id", "shared_list_items", ["list_id"])


def downgrade():
    op.drop_table("shared_list_items")
    op.drop_table("shared_list_members")
    op.drop_table("shared_lists")
