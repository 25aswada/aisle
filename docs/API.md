# API

Contract for Milestone 0 and Milestone 1. Local origin: `http://127.0.0.1:8000`.

Every response uses `Content-Type: application/json`. The routes are public. JSON object key order is not significant. Whitespace inside JSON is not significant.

Item search is not in this milestone. The only routes are:

- `GET /health`
- `GET /stores/nearby?lat=&lon=&limit=`
- `GET /stores/search?q=`
- `GET /stores/{store_id}`

`/openapi.json` on the running service must describe these routes and no others.

## Store object

List routes return a JSON array of store objects. `GET /stores/{store_id}` returns one store object.

| Field | JSON type | Meaning |
| --- | --- | --- |
| id | string | Lowercase UUID of the store. |
| name | string | Store name. |
| address | string | Single-line address. |
| latitude | number | WGS84 degrees. |
| longitude | number | WGS84 degrees. |
| retailer_name | string | `retailers.name` for this store. |
| distance_miles | number or null | Miles from the request origin. Null when the request has no origin. |

Nearby example:

```json
{
  "id": "3f1c2a4e-7b9d-4e2a-9c11-0a6b5d8e1f24",
  "name": "Downtown",
  "address": "100 Main St, Springfield",
  "latitude": 39.7817,
  "longitude": -89.6501,
  "retailer_name": "Target",
  "distance_miles": 1.4
}
```

Search and store-detail example (`distance_miles` is null):

```json
{
  "id": "3f1c2a4e-7b9d-4e2a-9c11-0a6b5d8e1f24",
  "name": "Downtown",
  "address": "100 Main St, Springfield",
  "latitude": 39.7817,
  "longitude": -89.6501,
  "retailer_name": "Target",
  "distance_miles": null
}
```

`distance_miles` is a JSON number in miles. The server does not round it to a fixed number of decimal places. When it is present, it is greater than or equal to 0.

## GET /health

Process liveness. This route does not query Postgres.

`200` body:

```json
{"status":"ok"}
```

The object has one field, `status`, and its value is the string `ok`.

## GET /stores/nearby

Stores nearest to a point.

| Query | Required | Type | Rules |
| --- | --- | --- | --- |
| lat | yes | number | -90 through 90. |
| lon | yes | number | -180 through 180. |
| limit | no | integer | Default 20. Minimum 1. Maximum 50. |

`200`: a JSON array of store objects, nearest first. Ties break by `id` ascending. Every object has a numeric `distance_miles`. No rows in range yields `[]`.

Missing `lat` or `lon`, a value outside the ranges above, or a `limit` outside 1 through 50 yields `422` with FastAPI's standard validation body.

## GET /stores/search

Manual store search. This route takes no coordinates. Device location stays optional because this route works without it. Every object has `distance_miles` set to null.

| Query | Required | Type | Rules |
| --- | --- | --- | --- |
| q | yes | string | Required. Trimmed. Must be non-empty. |

A store matches when `q` is a case-insensitive substring of the store name, the retailer name, or the address. Characters `%`, `_`, and `\` in `q` are literal, not pattern wildcards.

`200`: a JSON array ordered by store name ascending, then `id` ascending. No matches yields `[]`. This route has no `limit` parameter and returns every match.

Missing `q`, or `q` that is empty after trimming, yields `422`.

## GET /stores/{store_id}

One store. `store_id` is a UUID. `distance_miles` is null.

`200`: one store object.

A UUID that matches no row yields `404`:

```json
{"detail":"Store not found"}
```

A `store_id` that is not a UUID yields `422`.

## Status codes

| Status | When |
| --- | --- |
| 200 | Health, a store list (including empty), or a found store. |
| 404 | `store_id` is a UUID and no store has that id. Body is `{"detail":"Store not found"}`. |
| 422 | Query or path validation failed. Body is FastAPI's validation error. |
