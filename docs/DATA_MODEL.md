# Data model

SQLAlchemy models live in `backend/app/models.py`; Alembic migrations in
`backend/alembic/versions/`. Ids are integers.

## retailers, stores (Milestone 1)

- `retailers(id, name unique, domain null)`: `domain` is the website (`target.com`), used
  for logos (migration 0006). Seeding fills it for known retailers but never overwrites it.
- `stores(id, retailer_id → retailers, name, address, latitude, longitude,
  external_place_id null unique, store_number null)`: `latitude` is indexed for nearby
  search, and `external_place_id` (`osm:node/…`, `osm:way/…`) identifies stores imported
  from OpenStreetMap (migration 0011).

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

These come from the store's layout (`backend/app/store_zones.py`), which also keeps
`template` zones in sync with it (positions, categories, order; template zones the layout
dropped are removed). It never changes `verified` zones. Imported stores have no zones
until first used: the zones, layout, search, route and feedback endpoints copy the
chain's template then. Seeding syncs hand-added stores and stores already in use.

Layouts are per chain where researched (`backend/app/ai/chain_layouts.py`: Costco, Sam's
Club, Trader Joe's, Aldi, Walmart, Target, Whole Foods, Kroger, CVS, Walgreens, Home Depot,
Lowe's), built from public descriptions of each chain's usual pattern with sources noted
inline. Other retailers use a generic store-format layout from `catalog.py`. None are real
per-store floor plans, so the app labels maps "Typical <store> layout".

## Analytics (Milestone 7)

`analytics_events(id, name, device_id null, properties json, occurred_at, received_at)`.
Names come from a fixed list; properties are small scalars with no user text.

## Accounts

- `users(id, first_name, email null, phone null, wants_tips, created_at)`: email and phone
  are the first verified ones seen, used for display and for linking sign-in methods.
- `user_identities(id, user_id, provider, subject, email null, created_at)`, unique on
  `(provider, subject)`. `provider` is apple, google, phone or email; `subject` is the
  provider's stable id or the normalized phone/email.
- `auth_sessions(id, user_id, token_hash unique, device_id null, created_at, last_used_at,
  revoked_at null)`: only a SHA-256 of each token.
- `email_codes(id, email, code_hash, attempts, expires_at, consumed_at null, created_at)`.
- `code_requests(id, channel, target, device_id null, ip null, created_at)`: every code
  sent, for rate limits.

Deleting a user deletes its identities and revokes its sessions. Searches, reports and
analytics stay anonymous and are not linked to users.

- `apple_revocations(id, refresh_token null, authorization_code null, attempts,
  next_attempt_at, created_at)`: a deleted account's Apple sign-in that couldn't be
  revoked at the time. Not linked to any user; cleanup retries it and deletes the row on
  success, or gives up within two weeks.

## Aisle+

- `plus_entitlements(id, original_transaction_id unique, product_id, environment,
  expires_at, revoked_at, device_id, user_id null, updated_at)`: subscriptions proved with
  signed App Store transactions; renewals update the same row.
- `usage_counters(id, subject, feature, day, count)`, unique on `(subject, feature, day)`:
  the free tier's daily use. `subject` is `user:<id>`, `device:<install id>` or `ip:<addr>`.

## Shared lists

- `shared_lists(id uuid, owner_id, name, invite_code unique, version, created_at, updated_at)`.
- `shared_list_members(id, list_id, user_id, joined_at)`, unique on `(list_id, user_id)`.
- `shared_list_items(list_id, id (the phone's UUID), text, quantity, category_name, is_done,
  position, updated_at)`, keyed by `(list_id, id)`: the same phone id on two lists is two items.
- `shared_list_bans(id, list_id, user_id, created_at)`, unique on `(list_id, user_id)`: people
  the owner removed. They can't join that list again, whatever its code.
- `content_reports(id, reporter_id null, list_id null, reason, note null, snapshot, created_at,
  emailed_at null, reviewed_at null)`: reports of shared lists. `snapshot` is the list as it
  was reported (`name`, `owner_id`, `items`), so a report outlives the list and both
  accounts (the ids become null).

Deleting the owner's account hands each of their lists to its longest-standing other member
(`auth.accounts.delete_user`); a list with nobody else on it is deleted. Deleting a member's
account removes them.

### Seeding and imports

`python -m backend.app.seed` loads demo stores, the catalog (categories, concepts,
aliases) and `template` zones per store. Seeding never writes aisle labels or
product locations.

Real stores enter through `python -m backend.app.import_stores` (major US chains from
OpenStreetMap; see the backend README).

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
