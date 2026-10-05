"""Shared lists people can control: bans for removed members, reports of shared content,
and item ids that only need to be unique within their list."""
from alembic import op
import sqlalchemy as sa

revision = "0015"
down_revision = "0014"
branch_labels = None
depends_on = None

ITEM_COLUMNS = "id, list_id, text, quantity, category_name, is_done, position, updated_at"


def items_table(name: str, composite: bool):
    """shared_list_items keyed by (list_id, id), or by id alone as before."""
    key = [sa.PrimaryKeyConstraint("list_id", "id", name="pk_shared_list_items")] if composite else []
    op.create_table(
        name,
        sa.Column("id", sa.String(36), primary_key=not composite, nullable=False),
        sa.Column("list_id", sa.String(36), sa.ForeignKey("shared_lists.id", ondelete="CASCADE"), nullable=False),
        sa.Column("text", sa.String(200), nullable=False),
        sa.Column("quantity", sa.String(40), nullable=True),
        sa.Column("category_name", sa.String(80), nullable=True),
        sa.Column("is_done", sa.Boolean, nullable=False, server_default=sa.false()),
        sa.Column("position", sa.Float, nullable=False, server_default="0"),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        *key,
    )


def swap_items_table(composite: bool):
    # Copy into a new table and rename it, the same way on SQLite and Postgres.
    items_table("shared_list_items_new", composite)
    op.execute(f"INSERT INTO shared_list_items_new ({ITEM_COLUMNS}) SELECT {ITEM_COLUMNS} FROM shared_list_items")
    op.drop_index("ix_shared_list_items_list_id", table_name="shared_list_items")
    op.drop_table("shared_list_items")
    op.rename_table("shared_list_items_new", "shared_list_items")
    op.create_index("ix_shared_list_items_list_id", "shared_list_items", ["list_id"])


def upgrade():
    swap_items_table(composite=True)
    op.create_table(
        "shared_list_bans",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("list_id", sa.String(36), sa.ForeignKey("shared_lists.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("list_id", "user_id", name="uq_shared_list_ban"),
    )
    op.create_index("ix_shared_list_bans_list_id", "shared_list_bans", ["list_id"])
    op.create_index("ix_shared_list_bans_user_id", "shared_list_bans", ["user_id"])
    op.create_table(
        "content_reports",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("reporter_id", sa.Integer, sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True),
        sa.Column("list_id", sa.String(36), sa.ForeignKey("shared_lists.id", ondelete="SET NULL"), nullable=True),
        sa.Column("reason", sa.String(20), nullable=False),
        sa.Column("note", sa.String(500), nullable=True),
        sa.Column("snapshot", sa.JSON, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("emailed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("reviewed_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_content_reports_reporter_id", "content_reports", ["reporter_id"])
    op.create_index("ix_content_reports_list_id", "content_reports", ["list_id"])


def downgrade():
    op.drop_index("ix_content_reports_list_id", table_name="content_reports")
    op.drop_index("ix_content_reports_reporter_id", table_name="content_reports")
    op.drop_table("content_reports")
    op.drop_index("ix_shared_list_bans_user_id", table_name="shared_list_bans")
    op.drop_index("ix_shared_list_bans_list_id", table_name="shared_list_bans")
    op.drop_table("shared_list_bans")
    # Ids were global before: where two lists use the same one, the first list keeps it.
    op.execute("DELETE FROM shared_list_items WHERE EXISTS (SELECT 1 FROM shared_list_items other "
               "WHERE other.id = shared_list_items.id AND other.list_id < shared_list_items.list_id)")
    swap_items_table(composite=False)
