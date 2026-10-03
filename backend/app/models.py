from datetime import datetime, timezone

from sqlalchemy import (
    JSON, CheckConstraint, Column, DateTime, ForeignKey, String, Table, UniqueConstraint,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    pass


class Retailer(Base):
    __tablename__ = "retailers"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(200), unique=True)


class Store(Base):
    __tablename__ = "stores"
    __table_args__ = (
        CheckConstraint("latitude >= -90 AND latitude <= 90", name="valid_latitude"),
        CheckConstraint("longitude >= -180 AND longitude <= 180", name="valid_longitude"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    retailer_id: Mapped[int] = mapped_column(ForeignKey("retailers.id"), index=True)
    name: Mapped[str] = mapped_column(String(200))
    address: Mapped[str] = mapped_column(String(500))
    latitude: Mapped[float]
    longitude: Mapped[float]
    external_place_id: Mapped[str | None] = mapped_column(String(255))
    store_number: Mapped[str | None] = mapped_column(String(50))
    retailer: Mapped[Retailer] = relationship(lazy="joined")

    @property
    def retailer_name(self) -> str:
        return self.retailer.name


class Category(Base):
    __tablename__ = "categories"

    id: Mapped[int] = mapped_column(primary_key=True)
    slug: Mapped[str] = mapped_column(String(80), unique=True)
    name: Mapped[str] = mapped_column(String(120))
    # Items usually shelved nearby, shown as "look near" hints.
    neighbors: Mapped[list[str]] = mapped_column(JSON, default=list)


class ProductConcept(Base):
    """A generic product people search for ("maple syrup"), independent of brand."""
    __tablename__ = "product_concepts"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(200), unique=True)
    category_id: Mapped[int] = mapped_column(ForeignKey("categories.id"), index=True)
    category: Mapped[Category] = relationship(lazy="joined")
    aliases: Mapped[list["ProductAlias"]] = relationship(
        back_populates="concept", cascade="all, delete-orphan"
    )


class ProductAlias(Base):
    """Normalized search phrase (see ai.intent.normalize) that maps to a concept."""
    __tablename__ = "product_aliases"

    id: Mapped[int] = mapped_column(primary_key=True)
    concept_id: Mapped[int] = mapped_column(ForeignKey("product_concepts.id", ondelete="CASCADE"), index=True)
    alias: Mapped[str] = mapped_column(String(200), unique=True)
    concept: Mapped[ProductConcept] = relationship(back_populates="aliases")


zone_categories = Table(
    "store_zone_categories",
    Base.metadata,
    Column("zone_id", ForeignKey("store_zones.id", ondelete="CASCADE"), primary_key=True),
    Column("category_id", ForeignKey("categories.id", ondelete="CASCADE"), primary_key=True),
)


class StoreZone(Base):
    """A department or aisle inside one store.

    source "template" zones come from the store format's generic layout;
    "verified" zones were confirmed for this specific store. aisle_label is only
    set from real store data, never generated.
    """
    __tablename__ = "store_zones"
    __table_args__ = (UniqueConstraint("store_id", "name", name="uq_store_zone_name"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    store_id: Mapped[int] = mapped_column(ForeignKey("stores.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(120))
    aisle_label: Mapped[str | None] = mapped_column(String(40))
    source: Mapped[str] = mapped_column(String(20), default="template")
    sort_order: Mapped[int] = mapped_column(default=0)
    categories: Mapped[list[Category]] = relationship(secondary=zone_categories, lazy="selectin")


class ProductLocation(Base):
    """Where a concept is in a specific store, from a trusted data source."""
    __tablename__ = "product_locations"
    __table_args__ = (
        UniqueConstraint("store_id", "concept_id", "source", name="uq_product_location_source"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    store_id: Mapped[int] = mapped_column(ForeignKey("stores.id", ondelete="CASCADE"), index=True)
    concept_id: Mapped[int] = mapped_column(ForeignKey("product_concepts.id", ondelete="CASCADE"), index=True)
    zone_id: Mapped[int | None] = mapped_column(ForeignKey("store_zones.id", ondelete="SET NULL"))
    aisle_label: Mapped[str | None] = mapped_column(String(40))
    section: Mapped[str | None] = mapped_column(String(80))
    # "verified" (checked in store) or "retailer" (retailer-provided data).
    source: Mapped[str] = mapped_column(String(20))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    zone: Mapped[StoreZone | None] = relationship(lazy="joined")
    concept: Mapped[ProductConcept] = relationship(lazy="joined")
