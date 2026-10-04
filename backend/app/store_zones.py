"""Each store's zones come from its chain's layout template (ai.catalog.layout_for_retailer).

Imported stores start with no zones: the template is copied the first time a store is
used, so tens of thousands of stores don't each carry a copy until someone shops there.
"""
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .ai.catalog import layout_for_retailer
from .models import Category, Store, StoreZone


def sync_template_zones(session: Session, store: Store, categories: dict[str, Category]) -> None:
    """Make the store's template zones match its chain's layout (verified zones are never
    touched). Template zones the layout no longer has are removed; references to them
    become null. Entrance and checkout anchors always follow the layout."""
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


def has_template_zones(session: Session, store_id: int) -> bool:
    return session.scalar(select(StoreZone.id).where(
        StoreZone.store_id == store_id, StoreZone.source == "template"
    ).limit(1)) is not None


def ensure_zones(session: Session, store: Store) -> None:
    """Give a store its chain's template zones if it has none yet, and commit them."""
    if has_template_zones(session, store.id):
        return
    categories = {c.slug: c for c in session.scalars(select(Category))}
    sync_template_zones(session, store, categories)
    try:
        session.commit()
    except IntegrityError:
        # Another request laid out the same store first; its zones are the ones to use.
        session.rollback()


def get_store(session: Session, store_id: int) -> Store | None:
    """The store, with its zones laid out. Use this wherever zones are read or written."""
    store = session.get(Store, store_id)
    if store is not None:
        ensure_zones(session, store)
    return store
