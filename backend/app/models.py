from sqlalchemy import CheckConstraint, ForeignKey, String
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


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
