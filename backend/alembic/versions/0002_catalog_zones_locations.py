"""Milestone 3: categories, product concepts, store zones, product locations."""
from alembic import op
import sqlalchemy as sa

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "categories",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("slug", sa.String(80), nullable=False, unique=True),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("neighbors", sa.JSON(), nullable=False),
    )
    op.create_table(
        "product_concepts",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("name", sa.String(200), nullable=False, unique=True),
        sa.Column("category_id", sa.Integer(), sa.ForeignKey("categories.id"), nullable=False),
    )
    op.create_index("ix_product_concepts_category_id", "product_concepts", ["category_id"])
    op.create_table(
        "product_aliases",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("concept_id", sa.Integer(),
                  sa.ForeignKey("product_concepts.id", ondelete="CASCADE"), nullable=False),
        sa.Column("alias", sa.String(200), nullable=False, unique=True),
    )
    op.create_index("ix_product_aliases_concept_id", "product_aliases", ["concept_id"])
    op.create_table(
        "store_zones",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("store_id", sa.Integer(), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("aisle_label", sa.String(40), nullable=True),
        sa.Column("source", sa.String(20), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False),
        sa.UniqueConstraint("store_id", "name", name="uq_store_zone_name"),
    )
    op.create_index("ix_store_zones_store_id", "store_zones", ["store_id"])
    op.create_table(
        "store_zone_categories",
        sa.Column("zone_id", sa.Integer(), sa.ForeignKey("store_zones.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("category_id", sa.Integer(), sa.ForeignKey("categories.id", ondelete="CASCADE"), primary_key=True),
    )
    op.create_table(
        "product_locations",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("store_id", sa.Integer(), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("concept_id", sa.Integer(),
                  sa.ForeignKey("product_concepts.id", ondelete="CASCADE"), nullable=False),
        sa.Column("zone_id", sa.Integer(), sa.ForeignKey("store_zones.id", ondelete="SET NULL"), nullable=True),
        sa.Column("aisle_label", sa.String(40), nullable=True),
        sa.Column("section", sa.String(80), nullable=True),
        sa.Column("source", sa.String(20), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("store_id", "concept_id", "source", name="uq_product_location_source"),
    )
    op.create_index("ix_product_locations_store_id", "product_locations", ["store_id"])
    op.create_index("ix_product_locations_concept_id", "product_locations", ["concept_id"])


def downgrade():
    op.drop_table("product_locations")
    op.drop_table("store_zone_categories")
    op.drop_index("ix_store_zones_store_id", table_name="store_zones")
    op.drop_table("store_zones")
    op.drop_index("ix_product_aliases_concept_id", table_name="product_aliases")
    op.drop_table("product_aliases")
    op.drop_index("ix_product_concepts_category_id", table_name="product_concepts")
    op.drop_table("product_concepts")
    op.drop_table("categories")
