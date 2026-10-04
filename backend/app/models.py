from datetime import datetime, timezone
from uuid import uuid4

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
    # Website domain ("target.com"), used to look up the retailer's logo.
    domain: Mapped[str | None] = mapped_column(String(253))


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
    # Floor-plan anchors in normalized units (x 0..1 left to right, y 0..1 front to back).
    entrance_x: Mapped[float | None]
    entrance_y: Mapped[float | None]
    checkout_x: Mapped[float | None]
    checkout_y: Mapped[float | None]
    retailer: Mapped[Retailer] = relationship(lazy="joined")

    @property
    def retailer_name(self) -> str:
        return self.retailer.name

    @property
    def retailer_logo_url(self) -> str | None:
        from .logos import logo_url  # Local import: logos reads settings, models stays config-free.

        return logo_url(self.retailer.domain)


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
    # Approximate position on the floor plan, same units as the store anchors.
    x: Mapped[float | None]
    y: Mapped[float | None]
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


def new_id() -> str:
    return str(uuid4())


class SearchEvent(Base):
    """One item search and what the resolver answered. Anonymous."""
    __tablename__ = "search_events"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    store_id: Mapped[int | None] = mapped_column(ForeignKey("stores.id", ondelete="SET NULL"), index=True)
    query: Mapped[str] = mapped_column(String(200))
    item_normalized: Mapped[str] = mapped_column(String(200))
    concept_id: Mapped[int | None] = mapped_column(ForeignKey("product_concepts.id", ondelete="SET NULL"))
    category_slug: Mapped[str | None] = mapped_column(String(80))
    department: Mapped[str | None] = mapped_column(String(120))
    zone_id: Mapped[int | None] = mapped_column(ForeignKey("store_zones.id", ondelete="SET NULL"))
    source: Mapped[str] = mapped_column(String(20))
    confidence: Mapped[str] = mapped_column(String(10))
    device_id: Mapped[str | None] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)


class LocationObservation(Base):
    """A shopper's report: the item was found in a zone, or was not where we said.

    aisle_text is what the shopper typed. It is only shown once several reports agree.
    """
    __tablename__ = "location_observations"

    id: Mapped[int] = mapped_column(primary_key=True)
    store_id: Mapped[int] = mapped_column(ForeignKey("stores.id", ondelete="CASCADE"), index=True)
    search_event_id: Mapped[str | None] = mapped_column(ForeignKey("search_events.id", ondelete="SET NULL"))
    concept_id: Mapped[int | None] = mapped_column(ForeignKey("product_concepts.id", ondelete="SET NULL"), index=True)
    item_normalized: Mapped[str] = mapped_column(String(200), index=True)
    verdict: Mapped[str] = mapped_column(String(10))  # "found" or "not_here"
    zone_id: Mapped[int | None] = mapped_column(ForeignKey("store_zones.id", ondelete="SET NULL"))
    aisle_text: Mapped[str | None] = mapped_column(String(40))
    note: Mapped[str | None] = mapped_column(String(280))
    device_id: Mapped[str | None] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    zone: Mapped[StoreZone | None] = relationship(lazy="joined")


class AnalyticsEvent(Base):
    """Basic product analytics from the app. Anonymous; no free text from users."""
    __tablename__ = "analytics_events"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(40), index=True)
    device_id: Mapped[str | None] = mapped_column(String(64))
    properties: Mapped[dict] = mapped_column(JSON, default=dict)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)


class User(Base):
    """A shopper with an account. The app requires one; the API still answers without."""
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    # Stamped on this account's App Store purchases (StoreKit's appAccountToken), so an
    # Aisle+ subscription belongs to the account that bought it, not the Apple ID or phone.
    plus_token: Mapped[str] = mapped_column(String(36), unique=True, default=lambda: str(uuid4()))
    first_name: Mapped[str] = mapped_column(String(40), default="")
    # The first verified email or phone number seen for this person, for display and linking.
    email: Mapped[str | None] = mapped_column(String(320), index=True)
    phone: Mapped[str | None] = mapped_column(String(20))
    wants_tips: Mapped[bool] = mapped_column(default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    identities: Mapped[list["UserIdentity"]] = relationship(
        back_populates="user", cascade="all, delete-orphan", lazy="selectin"
    )


class UserIdentity(Base):
    """One way a user signs in: an Apple or Google account, a phone number or an email.

    subject is the provider's stable id (Apple/Google "sub"), or the normalized phone
    number or email for code sign-in.
    """
    __tablename__ = "user_identities"
    __table_args__ = (UniqueConstraint("provider", "subject", name="uq_identity_provider_subject"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    provider: Mapped[str] = mapped_column(String(10))  # apple, google, phone, email
    subject: Mapped[str] = mapped_column(String(320))
    email: Mapped[str | None] = mapped_column(String(320))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    user: Mapped[User] = relationship(back_populates="identities")


class AuthSession(Base):
    """A signed-in device. Only a SHA-256 of the token is stored, never the token."""
    __tablename__ = "auth_sessions"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    device_id: Mapped[str | None] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    last_used_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class EmailCode(Base):
    """A 6-digit sign-in code we emailed. Only its hash is stored."""
    __tablename__ = "email_codes"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(320), index=True)
    code_hash: Mapped[str] = mapped_column(String(64))
    attempts: Mapped[int] = mapped_column(default=0)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class CodeRequest(Base):
    """Every sign-in code we sent, by target, device and IP, for rate limits."""
    __tablename__ = "code_requests"

    id: Mapped[int] = mapped_column(primary_key=True)
    channel: Mapped[str] = mapped_column(String(10))  # sms or email
    target: Mapped[str] = mapped_column(String(320), index=True)
    device_id: Mapped[str | None] = mapped_column(String(64), index=True)
    ip: Mapped[str | None] = mapped_column(String(45), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)


class PlusEntitlement(Base):
    """An Aisle+ subscription the app proved with a signed App Store transaction.

    Keyed by the subscription's original transaction id; renewals update expires_at.
    It applies to the account it was bought for (or later restored to); device_id is kept
    only as a record of where it was sent from.
    """
    __tablename__ = "plus_entitlements"

    id: Mapped[int] = mapped_column(primary_key=True)
    original_transaction_id: Mapped[str] = mapped_column(String(64), unique=True)
    product_id: Mapped[str] = mapped_column(String(100))
    environment: Mapped[str] = mapped_column(String(20))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    device_id: Mapped[str | None] = mapped_column(String(64), index=True)
    user_id: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"), index=True)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class UsageCounter(Base):
    """How many times a free shopper used a limited feature on a (UTC) day."""
    __tablename__ = "usage_counters"
    __table_args__ = (UniqueConstraint("subject", "feature", "day", name="uq_usage_subject_feature_day"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    # "user:7", "device:<install id>" or "ip:<address>".
    subject: Mapped[str] = mapped_column(String(80))
    feature: Mapped[str] = mapped_column(String(20))  # photo_search or follow_up
    day: Mapped[str] = mapped_column(String(10))  # YYYY-MM-DD
    count: Mapped[int] = mapped_column(default=0)


class SharedList(Base):
    """A shopping list kept on the server so a family can share it (Aisle+ to share)."""
    __tablename__ = "shared_lists"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    owner_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(60))
    # Short code people type or tap to join, e.g. "K7Q2MX".
    invite_code: Mapped[str] = mapped_column(String(12), unique=True)
    # Bumped on every change, so phones can ask "anything new?" cheaply.
    version: Mapped[int] = mapped_column(default=1)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    members: Mapped[list["SharedListMember"]] = relationship(
        back_populates="shared_list", cascade="all, delete-orphan", lazy="selectin"
    )
    items: Mapped[list["SharedListItem"]] = relationship(
        back_populates="shared_list", cascade="all, delete-orphan", lazy="selectin"
    )


class SharedListMember(Base):
    __tablename__ = "shared_list_members"
    __table_args__ = (UniqueConstraint("list_id", "user_id", name="uq_shared_list_member"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    list_id: Mapped[str] = mapped_column(ForeignKey("shared_lists.id", ondelete="CASCADE"), index=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    joined_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    shared_list: Mapped[SharedList] = relationship(back_populates="members")
    user: Mapped[User] = relationship(lazy="joined")


class SharedListItem(Base):
    """One line on a shared list. The id comes from the phone that added it."""
    __tablename__ = "shared_list_items"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    list_id: Mapped[str] = mapped_column(ForeignKey("shared_lists.id", ondelete="CASCADE"), index=True)
    text: Mapped[str] = mapped_column(String(200))
    quantity: Mapped[str | None] = mapped_column(String(40))
    category_name: Mapped[str | None] = mapped_column(String(80))
    is_done: Mapped[bool] = mapped_column(default=False)
    position: Mapped[float] = mapped_column(default=0)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    shared_list: Mapped[SharedList] = relationship(back_populates="items")
