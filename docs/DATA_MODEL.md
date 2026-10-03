# Data model

SQLAlchemy models live in `backend/app/models.py`; Alembic migrations in
`backend/alembic/versions/`. Ids are integers.

## retailers, stores (Milestone 1)

- `retailers(id, name unique)`
- `stores(id, retailer_id → retailers, name, address, latitude, longitude,
  external_place_id null, store_number null)`

## Catalog and locations (Milestone 3)

| Table | Purpose |
| --- | --- |
| `categories(id, slug unique, name, neighbors json)` | Product category; `neighbors` are "look near" hints. |
| `product_concepts(id, name unique, category_id)` | Generic product people search for ("maple syrup"). |
| `product_aliases(id, concept_id, alias unique)` | Normalized search phrases (`ai.intent.normalize`) for a concept. |
| `store_zones(id, store_id, name, aisle_label null, source, sort_order)` | A department or aisle in one store. `source` is `template` (generic layout for the store format) or `verified` (confirmed for this store). Unique per store by name. |
| `store_zone_categories(zone_id, category_id)` | Which categories a zone holds. |
| `product_locations(id, store_id, concept_id, zone_id null, aisle_label null, section null, source, updated_at)` | Where a concept is in a specific store. `source` is `verified` or `retailer`. Unique per (store, concept, source). |

### Seeding and imports

`python -m backend.app.seed` loads demo stores, the catalog (categories, concepts,
aliases) and `template` zones per store. Seeding never writes aisle labels or
product locations.

Real locations enter through `python -m backend.app.import_locations file.csv`
(columns `store_id,item,source,department,aisle,section`). That importer is the only
writer of `aisle_label`.

### Resolver source priority

`backend/app/resolver.py`, best first:

1. `product_locations` with source `verified`, then `retailer` → `source: "database"`, high confidence, aisle/section from the row.
2. A `verified` store zone holding the category → `"store_layout"`, medium.
3. The AI model, when configured → `"model"`.
4. The deterministic catalog, using the store's template zone → `"fallback"`.

The model is never called when step 1 or 2 matches.
