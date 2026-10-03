# API

Local origin: `http://127.0.0.1:8000`. JSON in and out. No accounts or auth.
`/docs` on the running service shows the live OpenAPI schema. This document and
`ios/Aisle/Networking/APIClient.swift` must change together.

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
| retailer | object | `{id, name}` |
| retailer_name | string | flat copy of `retailer.name`; the iOS client reads this |
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
  "query": "maple syrup",
  "item": "maple syrup",
  "modifiers": [],
  "quantity": null,
  "store_id": 2,
  "category": {"slug": "syrups-sweeteners", "name": "Syrups & Sweeteners"},
  "location": {
    "department": "Breakfast/Pantry",
    "aisle": null,
    "section": null,
    "neighbors": ["pancake mix", "honey", "sweeteners"]
  },
  "availability": "likely",
  "confidence": "medium",
  "source": "fallback"
}
```

| Field | Values |
| --- | --- |
| item | the item phrase parsed from the query |
| modifiers | words like `organic` that don't change the item |
| quantity | e.g. `"2 gallons"`, or null |
| category | null when the item isn't recognized |
| location.department | department or zone name, or null when unknown |
| location.aisle, location.section | **only** set when a database row supports it; never inferred |
| location.neighbors | up to 4 items usually shelved nearby |
| availability | `likely`, `unlikely` (this store format usually doesn't stock it), `unknown` |
| confidence | `high`, `medium`, `low` |
| source | `database`, `observations`, `store_layout`, `model`, `fallback` |

The response is structured data only. The app composes all display text.
