"""Representative demo locations; coordinates are approximate, not live listings."""
from sqlalchemy import select
from sqlalchemy.orm import Session

from .ai.catalog import CATEGORIES, layout_for_retailer
from .ai.intent import normalize
from .database import get_engine
from .models import Category, ProductAlias, ProductConcept, Retailer, Store, StoreZone

# Leave provider IDs and store numbers null rather than inventing identifiers.
STORES = (
    ("Costco", "Costco King of Prussia", "201 Allendale Rd, King of Prussia, PA 19406", 40.0925, -75.3855),
    ("Trader Joe's", "Trader Joe's Center City", "2121 Market St, Philadelphia, PA 19103", 39.9546, -75.1761),
    ("Walmart", "Walmart South Philadelphia", "1675 S Christopher Columbus Blvd, Philadelphia, PA 19148", 39.9220, -75.1404),
    ("Target", "Target Washington Square", "1128 Chestnut St, Philadelphia, PA 19107", 39.9502, -75.1600),
    ("CVS", "CVS Rittenhouse", "1826 Chestnut St, Philadelphia, PA 19103", 39.9521, -75.1713),
    ("Home Depot", "Home Depot South Philadelphia", "1651 S Christopher Columbus Blvd, Philadelphia, PA 19148", 39.9250, -75.1402),
)


def seed_stores(session: Session) -> None:
    for retailer_name, name, address, latitude, longitude in STORES:
        retailer = session.scalar(select(Retailer).where(Retailer.name == retailer_name))
        if retailer is None:
            retailer = Retailer(name=retailer_name)
            session.add(retailer)
            session.flush()
        existing = session.scalar(select(Store).where(
            Store.retailer_id == retailer.id, Store.name == name, Store.address == address
        ))
        if existing is None:
            session.add(Store(
                retailer_id=retailer.id, name=name, address=address,
                latitude=latitude, longitude=longitude,
            ))
    session.commit()


def seed_catalog(session: Session) -> None:
    """Load catalog categories and concepts. Existing rows are left as they are."""
    categories = {c.slug: c for c in session.scalars(select(Category))}
    known_aliases = set(session.scalars(select(ProductAlias.alias)))
    known_names = set(session.scalars(select(ProductConcept.name)))
    for definition in CATEGORIES:
        category = categories.get(definition.slug)
        if category is None:
            category = Category(slug=definition.slug, name=definition.name, neighbors=list(definition.neighbors))
            session.add(category)
            categories[definition.slug] = category
        for term in definition.terms:
            alias = normalize(term)
            if alias in known_aliases or term in known_names:
                continue
            known_aliases.add(alias)
            known_names.add(term)
            session.add(ProductConcept(name=term, category=category, aliases=[ProductAlias(alias=alias)]))
    session.commit()


def seed_store_zones(session: Session) -> None:
    """Give each store the generic layout for its store format.

    Stores without zones get template zones (department names only, no aisle labels).
    Template zones and store anchors missing coordinates are backfilled from the
    layout. Verified data is never overwritten.
    """
    categories = {c.slug: c for c in session.scalars(select(Category))}
    for store in session.scalars(select(Store)):
        layout = layout_for_retailer(store.retailer_name)
        if store.entrance_x is None or store.entrance_y is None:
            store.entrance_x, store.entrance_y = layout.entrance
        if store.checkout_x is None or store.checkout_y is None:
            store.checkout_x, store.checkout_y = layout.checkout
        existing = {z.name: z for z in session.scalars(select(StoreZone).where(StoreZone.store_id == store.id))}
        if not existing:
            for order, zone in enumerate(layout.zones):
                session.add(StoreZone(
                    store_id=store.id, name=zone.name, source="template", sort_order=order,
                    x=zone.x, y=zone.y,
                    categories=[categories[slug] for slug in zone.categories if slug in categories],
                ))
            continue
        for zone in layout.zones:
            row = existing.get(zone.name)
            if row is not None and row.source == "template" and (row.x is None or row.y is None):
                row.x, row.y = zone.x, zone.y
    session.commit()


def seed_all(session: Session) -> None:
    seed_stores(session)
    seed_catalog(session)
    seed_store_zones(session)


if __name__ == "__main__":
    with Session(get_engine()) as session:
        seed_all(session)
    print("Demo data seeded.")
