"""Representative demo locations; coordinates are approximate, not live listings."""
from sqlalchemy import select
from sqlalchemy.orm import Session

from .ai.catalog import CATEGORIES
from .ai.intent import normalize
from .database import get_engine
from .models import Category, ProductAlias, ProductConcept, Retailer, Store, StoreZone
from .store_zones import sync_template_zones

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
    """Keep laid-out stores' template zones in step with their chain's layout.

    Hand-added stores (no external place ID) are always laid out. Imported stores are
    laid out the first time they're used (store_zones.ensure_zones), so only those
    already in use are synced here.
    """
    categories = {c.slug: c for c in session.scalars(select(Category))}
    in_use = set(session.scalars(select(StoreZone.store_id).where(StoreZone.source == "template").distinct()))
    for store in session.scalars(select(Store)):
        if store.external_place_id is None or store.id in in_use:
            sync_template_zones(session, store, categories)
    session.commit()


def seed_all(session: Session) -> None:
    seed_stores(session)
    seed_catalog(session)
    seed_store_zones(session)


if __name__ == "__main__":
    with Session(get_engine()) as session:
        seed_all(session)
    print("Demo data seeded.")
