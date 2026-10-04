"""Representative demo locations; coordinates are approximate, not live listings."""
from sqlalchemy import select
from sqlalchemy.orm import Session

from .ai.catalog import CATEGORIES, layout_for_retailer
from .ai.intent import normalize
from .database import get_engine
from .models import Category, ProductAlias, ProductConcept, Retailer, Store, StoreZone

# Retailer website domains, used for logos.
RETAILER_DOMAINS = {
    "Costco": "costco.com",
    "Trader Joe's": "traderjoes.com",
    "Walmart": "walmart.com",
    "Target": "target.com",
    "CVS": "cvs.com",
    "Home Depot": "homedepot.com",
}

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
        if retailer.domain is None:  # Backfill only; never overwrite an edited domain.
            retailer.domain = RETAILER_DOMAINS.get(retailer_name)
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
    """Keep each store's template zones in step with its chain's layout.

    Template zones are added, moved, re-categorised and reordered to match the current
    layout, and template zones the layout no longer has are removed (references to them
    become null). Verified zones are never touched. Entrance and checkout anchors always
    follow the layout, since stores have no hand-set anchors yet.
    """
    categories = {c.slug: c for c in session.scalars(select(Category))}
    for store in session.scalars(select(Store)):
        layout = layout_for_retailer(store.retailer_name)
        store.entrance_x, store.entrance_y = layout.entrance
        store.checkout_x, store.checkout_y = layout.checkout
        existing = {z.name: z for z in session.scalars(select(StoreZone).where(StoreZone.store_id == store.id))}
        wanted = {zone.name for zone in layout.zones}
        for order, zone in enumerate(layout.zones):
            zone_categories = [categories[slug] for slug in zone.categories if slug in categories]
            row = existing.get(zone.name)
            if row is None:
                session.add(StoreZone(
                    store_id=store.id, name=zone.name, source="template", sort_order=order,
                    x=zone.x, y=zone.y, categories=zone_categories,
                ))
            elif row.source == "template":
                row.x, row.y, row.sort_order = zone.x, zone.y, order
                row.categories = zone_categories
        for name, row in existing.items():
            if row.source == "template" and name not in wanted:
                session.delete(row)
    session.commit()


def seed_all(session: Session) -> None:
    seed_stores(session)
    seed_catalog(session)
    seed_store_zones(session)


if __name__ == "__main__":
    with Session(get_engine()) as session:
        seed_all(session)
    print("Demo data seeded.")
