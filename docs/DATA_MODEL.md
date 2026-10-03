# Data model

SQLAlchemy models live in `backend/app/models.py`; Alembic migrations in
`backend/alembic/versions/`. Ids are integers.

## retailers, stores (Milestone 1)

- `retailers(id, name unique, domain null)`: `domain` is the website (`target.com`), used
  for logos (migration 0006). Seeding fills it for known retailers but never overwrites it.
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

## Feedback and events (Milestone 4)

| Table | Purpose |
| --- | --- |
| `search_events(id uuid string, store_id null, query, item_normalized, concept_id null, category_slug null, department null, zone_id null, source, confidence, device_id null, created_at)` | One row per `POST /search`, with what was answered. |
| `location_observations(id, store_id, search_event_id null, concept_id null, item_normalized, verdict, zone_id null, aisle_text null, note null, device_id null, created_at)` | Shopper reports. `verdict` is `found` or `not_here`. Unknown items are grouped by `item_normalized`. |

## Coordinates (Milestone 6)

- `store_zones.x`, `store_zones.y`: approximate floor-plan position (0..1), null when unknown.
- `stores.entrance_x/_y`, `stores.checkout_x/_y`: route start and end anchors.

Seeding fills these from the store format's layout template and backfills missing
values on template zones. It never changes `verified` zones.

## Analytics (Milestone 7)

`analytics_events(id, name, device_id null, properties json, occurred_at, received_at)`.
Names come from a fixed list; properties are small scalars with no user text.

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
2. Shopper consensus from `location_observations` → `"observations"` (see `API.md`).
3. A `verified` store zone holding the category → `"store_layout"`, medium.
4. The AI model, when configured → `"model"`.
5. The deterministic catalog, using the store's template zone → `"fallback"`.

The model is never called when steps 1–3 match.
