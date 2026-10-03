# API

Local origin: `http://127.0.0.1:8000`. JSON in and out. No accounts or auth.
`/docs` on the running service shows the live OpenAPI schema. This document and
`ios/Aisle/Networking/APIClient.swift` must change together.

## Device header

The app sends `X-Aisle-Device: <random install id>` on every request. It is
anonymous (no account, not a hardware id). The server stores it on search events
and observations so repeat reports from one install count once. It is optional.

## Identifiers

Database ids are integers in JSON. The iOS client stores `Store.id` as a string
and sends it back as an integer `store_id`.

## Stores

### Store object

| Field | Type | Notes |
| --- | --- | --- |
| id | integer | |
| retailer_id | integer | |
| name | string | |
| address | string | single line |
| latitude, longitude | number | WGS84 |
| external_place_id, store_number | string or null | null in demo data |
| retailer | object | `{id, name, domain}`; `domain` (e.g. `target.com`) may be null |
| retailer_name | string | flat copy of `retailer.name`; the iOS client reads this |
| retailer_logo_url | string \| null | logo.dev image for `retailer.domain`; null without a domain or `LOGO_DEV_PUBLISHABLE_KEY`. Unknown domains return 404 (no generated monogram), so clients fall back to their own tile. |
| distance_miles | number | only on `/stores/nearby` |

- `GET /health` → `{"status":"ok"}`. No database access.
- `GET /stores/nearby?lat=&lon=&limit=` → `{"stores":[...],"message":null}`, nearest
  first. `limit` 1–100, default 20. Missing `lat` or `lon` → `{"stores":[],"message":"..."}`
  with status 200.
- `GET /stores/search?q=` → bare JSON array, case-insensitive substring of store
  name, retailer name, or address. Whitespace-only `q` → `[]`.
- `GET /stores/{store_id}` → one store, or 404 `{"detail":"Store not found"}`.

## Item search

### POST /search

Request:

```json
{"query": "maple syrup", "store_id": 2}
```

`query` is 1–200 characters and not blank. `store_id` is optional; without it the
generic grocery layout is used. Unknown `store_id` → 404. Invalid body → 422.

Response (Trader Joe's, no database row for this item):

```json
{
  "search_id": "6f0c1d1e-8a43-4d1e-9c55-3f0f5d3a9e10",
  "query": "maple syrup",
  "item": "maple syrup",
  "modifiers": [],
  "quantity": null,
  "store_id": 2,
  "concept": {"id": 118, "name": "maple syrup"},
  "category": {"slug": "syrups-sweeteners", "name": "Syrups & Sweeteners"},
  "location": {
    "department": "Breakfast/Pantry",
    "zone_id": 17,
    "aisle": null,
    "section": null,
    "neighbors": ["pancake mix", "honey", "sweeteners"]
  },
  "availability": "likely",
  "confidence": "medium",
  "source": "fallback",
  "reports": {"found": 0, "not_here": 0}
}
```

| Field | Values |
| --- | --- |
| item | the item phrase parsed from the query |
| modifiers | words like `organic` that don't change the item |
| quantity | e.g. `"2 gallons"`, or null |
| concept | matched product concept, or null |
| category | null when the item isn't recognized |
| location.department | department or zone name, or null when unknown |
| location.zone_id | the store zone id, when the store has zones |
| location.aisle, location.section | **only** set when a database row supports it; never inferred |
| location.neighbors | up to 4 items usually shelved nearby |
| availability | `likely`, `unlikely` (this store format usually doesn't stock it), `unknown` |
| confidence | `high`, `medium`, `low` |
| source | `database`, `observations`, `store_layout`, `model`, `fallback` |
| search_id | id of the recorded search event; pass it back with feedback. Null if logging failed |
| reports | distinct shoppers who found / didn't find it in the suggested zone; null without a store or zone |

Source priority is described in `DATA_MODEL.md`. A database row for the item at this
store always beats the model.

The response is structured data only. The app composes all display text.

## Feedback (Milestone 4)

### GET /stores/{store_id}/zones

The store's departments, for the correction picker. 404 for an unknown store.

```json
[{"id": 17, "name": "Breakfast/Pantry", "aisle_label": null, "source": "template"}]
```

### POST /feedback

"Found it", "Not here", and corrections. Status 201.

```json
{"store_id": 2, "item": "maple syrup", "verdict": "found",
 "search_id": "6f0c…", "zone_id": 21, "aisle": "Aisle 9", "note": null}
```

| Field | Rules |
| --- | --- |
| verdict | `found` or `not_here` |
| zone_id | optional. For `found`, where it was (the suggested zone, or a correction). For `not_here`, the zone it wasn't in. Must belong to the store, else 422 |
| aisle | optional, ≤ 40 chars, kept only for `found`. Shown in search results only after 2+ shoppers type the same text |
| search_id | optional; unknown ids are ignored |

Response:

```json
{"id": 5, "store_id": 2, "verdict": "found", "zone_id": 21, "concept_id": 118,
 "reports": {"found": 1, "not_here": 0}}
```

Consensus rule: a zone becomes the answer (`source: "observations"`) when at least
2 distinct shoppers found the item there and they outnumber "not here" reports for
that zone; 3+ with no "not here" makes it high confidence. Two or more "not here"
reports that outnumber "found" for the suggested zone drop confidence to low.
Database rows still win over observations.

## Shopping lists (Milestone 5)

Lists live on the device (no accounts). The server only parses text.

### POST /lists/parse

```json
{"text": "milk eggs bananas toothpaste"}
```

```json
{"items": [
  {"text": "milk", "quantity": null, "category": {"slug": "dairy", "name": "Milk & Dairy"}},
  {"text": "eggs", "quantity": null, "category": {"slug": "eggs", "name": "Eggs"}},
  {"text": "bananas", "quantity": null, "category": {"slug": "produce-fruit", "name": "Fruit"}},
  {"text": "toothpaste", "quantity": null, "category": {"slug": "oral-care", "name": "Oral Care"}}
]}
```

`text` ≤ 2000 characters; at most 100 items are returned. Newlines, commas,
semicolons, bullets, and " and " (outside phrases like "half and half") split items.
Without separators, words are segmented by known catalog phrases ("maple syrup paper
towels" is two items); consecutive unknown words stay one item. Leading quantities
("2", "a dozen", "half gallon") go to `quantity`. Unknown items have `category: null`.
When the server is unreachable, the app splits on separators or spaces locally.

## Route (Milestone 6)

### POST /route

Orders the list into stops for Start Shopping mode.

```json
{"store_id": 2, "items": [{"id": "client-uuid-1", "text": "milk"}, {"id": "client-uuid-2", "text": "bananas"}]}
```

1–100 items; `id` is the client's item id (≤ 64 chars) and is echoed back. Unknown
store → 404.

```json
{
  "store_id": 2,
  "stops": [
    {"order": 1, "zone_id": 12, "department": "Flowers & Produce", "x": 0.1, "y": 0.2,
     "items": [{"id": "client-uuid-2", "text": "bananas", "aisle": null, "section": null,
                "neighbors": ["apples", "berries"], "confidence": "medium", "source": "fallback"}]},
    {"order": 2, "zone_id": 19, "department": "Dairy & Eggs", "x": 0.15, "y": 0.9, "items": [...]}
  ],
  "unplaced": [{"id": "client-uuid-3", "text": "hammer", "reason": "not_carried"}],
  "distance": 3.19
}
```

Each item is resolved like `POST /search` (same source priority; at most 5 AI calls
per route). Items in the same zone share a stop. Stops run from the store's entrance to
its checkout: nearest neighbor, then 2-opt, using Manhattan distance on zone `x`/`y`
(normalized floor-plan units: x 0..1 left to right, y 0..1 front to back). Coordinates
are approximate template positions. Zones without coordinates come last. `unplaced`
reasons: `unknown` (no department) or `not_carried` (the store format usually doesn't
stock it).

## Analytics and errors (Milestone 7)

### POST /events

Basic, anonymous product analytics. Status 202.

```json
{"events": [
  {"name": "search_submitted", "occurred_at": "2026-10-03T19:00:00Z",
   "properties": {"source": "fallback", "confidence": "medium", "has_store": true, "cached": false}}
]}
```

- 1–50 events per batch. `occurred_at` is optional and clamped to the server clock.
- `name` must be one of: `app_opened`, `store_selected`, `search_submitted`, `search_failed`,
  `recent_search_tapped`, `feedback_sent`, `list_items_added`, `shopping_started`,
  `shopping_item_found`, `shopping_item_skipped`, `shopping_finished`.
- `properties`: at most 12 scalar values (string ≤ 80 chars, number, bool, null). The app
  never sends queries or item text. Users can turn analytics off in the You tab.

### Errors

- Validation errors: 422 with FastAPI's standard body.
- Not found: 404 `{"detail": "..."}`.
- Unexpected failures: 500 `{"detail": "Something went wrong. Please try again."}`. No stack traces.

### Caching

- `GET /stores/{id}/zones` sends `Cache-Control: public, max-age=300`.
- The server caches AI answers in memory for 6 hours per (store format, retailer, item).
- The app caches search results for 5 minutes per store and query, and drops an item's
  entry after feedback for it.
