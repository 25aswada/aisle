# API

Local origin: `http://127.0.0.1:8000`. JSON in and out. Accounts are optional: only `/me` and
`/auth/signout` need a session (see Accounts below); everything else is public.
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
| external_place_id, store_number | string or null | `osm:way/123` and the chain's store number for stores imported from OpenStreetMap; null in demo data |
| retailer | object | `{id, name, domain}`; `domain` (e.g. `target.com`) may be null |
| retailer_name | string | flat copy of `retailer.name`; the iOS client reads this |
| retailer_logo_url | string \| null | logo.dev image for `retailer.domain`; null without a domain or `LOGO_DEV_PUBLISHABLE_KEY`. Unknown domains return 404 (no generated monogram), so clients fall back to their own tile. |
| distance_miles | number | only on `/stores/nearby`, and on `/stores/search` with `lat` and `lon` |

- `GET /health` → `{"status":"ok"}`. No database access.
- `GET /stores/nearby?lat=&lon=&limit=` → `{"stores":[...],"message":null}`, nearest
  first. `limit` 1–100, default 20. Missing `lat` or `lon` → `{"stores":[],"message":"..."}`
  with status 200.
- `GET /stores/search?q=&lat=&lon=&limit=` → bare JSON array of stores whose name,
  retailer name or address contain every word of `q` (case-insensitive), so
  `giant eagle strongsville` works. With `lat` and `lon`, nearest first with
  `distance_miles`; otherwise by name. `limit` 1–100, default 50. Whitespace-only `q` → `[]`.
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

The response is structured data, plus `explanation`: with an AI key, the model's
written "where to find it" reply, shown as written (null without a key or on failure).

### POST /chat

A follow-up in the conversation a search started. Send the whole conversation so far,
ending with the shopper's new message:

```json
{
  "store_id": 2,
  "messages": [
    {"role": "user", "content": "cookies"},
    {"role": "assistant", "content": "If you're inside Costco right now, ..."},
    {"role": "user", "content": "I'm at the bakery and don't see them"}
  ]
}
```

1–40 messages, each up to 4000 characters; the last must be `user`. A `user` message may
also carry `"image"`, a base64 JPEG or PNG (about 1024 px; at most 4 MB of base64), and
then its text may be empty. The app sends only the newest photo. Unknown `store_id` →
404. Invalid body or image → 422.

```json
{"reply": "Check the tables right in front of the bakery ovens, ...", "search": null}
```

`reply` is null when no AI key is set or the provider couldn't answer.

While writing the reply, the server asks the model whether the newest message wants a
product found that the conversation hasn't located yet ("what about milk", a photo of
something to find). If so, `search` is that item's `POST /search` response for this store
(recorded as a search, so its `search_id` takes feedback; its `explanation` is null since
`reply` already answers). Small talk, prices, "I don't see them" and the like get
`"search": null`.

### POST /identify

What the shopper photographed, as a search phrase the app then sends to `POST /search`.

```json
{"store_id": 2, "image": "/9j/4AAQ...", "note": "the blue one"}
```

`store_id` and `note` (what the shopper typed with the photo, up to 200 characters) are
optional. Unknown `store_id` → 404. Invalid image → 422.

```json
{"item": "oat milk"}
```

`item` is 1–5 words, or null when there's no product in the photo, no AI key is set, or
the provider couldn't answer.

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

Lists live on the device. The server only parses text.

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

### POST /lists/scan

A photo of a shopping list (handwritten, printed or on a screen), read by the AI and then
split exactly like `POST /lists/parse` text.

```json
{"image": "/9j/4AAQ..."}
```

`image` is a base64 JPEG or PNG (at most 4 MB of base64); anything else → 422. The
response has the same shape as `/lists/parse`. Crossed-out items, headings, dates and
prices are left out. `items` is empty when there's no list in the photo, no AI key is set,
or the provider couldn't read it.

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

### POST /route/multi

One trip across 2–4 stores (Aisle+; 402 with `feature: "multi_store"` otherwise).

```json
{"store_ids": [2, 9], "items": [{"id": "a", "text": "milk"}, {"id": "b", "text": "hammer"}]}
```

Each item goes to the first store, in the order sent, that likely carries it in a known
department; failing that, the first that might. Stores that end up with nothing are left
out. Each leg is a `/route` response for one store (with `store_name`, `retailer_name`), in
the shopper's order. Top-level `unplaced` holds items none of the stores would carry. At
most 10 AI calls across the whole trip. Repeated or unknown stores → 422 / 404.

```json
{"legs": [{"store_id": 2, "store_name": "Trader Joe's Center City", "retailer_name": "Trader Joe's",
           "stops": [...], "unplaced": [], "distance": 2.1},
          {"store_id": 9, "store_name": "Home Depot South Philadelphia", "retailer_name": "Home Depot",
           "stops": [...], "unplaced": [], "distance": 1.4}],
 "unplaced": [{"id": "c", "text": "flux capacitor", "reason": "unknown"}]}
```

## Accounts

Optional. Sign in with an SMS code (Twilio Verify), an email code (sent with Resend),
Sign in with Apple or Google. Every sign-in returns:

```json
{"token": "…", "is_new": true,
 "user": {"id": 7, "first_name": "", "email": null, "phone": "+12155550123",
          "wants_tips": false, "providers": ["phone"]}}
```

Send the token as `Authorization: Bearer <token>`. It doesn't expire; signing out or
deleting the account revokes it. Only a SHA-256 of it is stored. `is_new` means this
sign-in created the account, so the app asks for a first name (`PATCH /me`).

| Route | Body | Notes |
| --- | --- | --- |
| `POST /auth/phone/start` | `{"phone"}` | Ten digits are taken as US; otherwise start with `+`. Returns `{"sent_to": "+1 •••• 0123", "retry_after": 30}` |
| `POST /auth/phone/verify` | `{"phone", "code"}` | 400 wrong code, expired code, or too many tries (429) |
| `POST /auth/email/start` | `{"email"}` | Same response shape; the email shows in full |
| `POST /auth/email/verify` | `{"email", "code"}` | Codes last 10 minutes and 5 tries, and work once |
| `POST /auth/apple` | `{"identity_token", "nonce"?, "first_name"?}` | Token checked against Apple's keys, audience `APPLE_BUNDLE_ID`; `nonce` is the raw value whose SHA-256 the app sent Apple |
| `POST /auth/google` | `{"id_token", "nonce"?}` | Token checked against Google's keys, audience `GOOGLE_IOS_CLIENT_ID` |
| `GET /me` | | 401 when the session ended |
| `PATCH /me` | `{"first_name"?, "wants_tips"?}` | |
| `DELETE /me` | | Deletes the account and its sign-ins; 204 |
| `POST /auth/signout` | | Revokes this session; 204 |

- Signing in with a new method whose verified email matches an existing account adds it
  to that account.
- Code sends are limited: 30 seconds apart and 5 an hour per phone or email, 10 an hour
  per device, 20 an hour per IP (429 with a message the app shows).
- A method without keys in `backend/.env` answers 503 with a message to try another way.
- Errors carry `{"detail": "…"}` meant for the shopper.

## Shared lists

Lists live on the phone; sharing one (Aisle+) moves a copy here so everyone on it sees
the same items. Every route needs a session. Joining with an invite code is free.

| Route | Body | Notes |
| --- | --- | --- |
| `GET /lists` | | Summaries of the lists you're on: `id, name, version, is_owner, item_count, members` |
| `POST /lists` | `{"name", "items": [item…]}` | Shares a list; 402 without Aisle+. 201 with the list |
| `POST /lists/join` | `{"code"}` | Case and spacing don't matter; 404 for an unknown code |
| `GET /lists/{id}` | | The list; 404 if it's gone or you're not on it |
| `POST /lists/{id}/changes` | `{"changes": [{"op": "upsert", "item": item} \| {"op": "delete", "id"}]}` | Latest write to an item wins; bumps `version` |
| `PATCH /lists/{id}` | `{"name"}` | |
| `DELETE /lists/{id}` | | The owner deletes it for everyone; anyone else leaves. 204 |

An item is `{"id", "text", "quantity", "category_name", "is_done", "position"}`; `id` is the
phone's UUID for it. A list is `{"id", "name", "invite_code", "version", "is_owner",
"members": [{"first_name", "is_owner", "is_you"}], "items": [item…]}`, up to 500 items.
The app keeps unconfirmed changes on the phone, sends them after a short pause, polls every
few seconds while the list is open, and replays its own pending changes on top of the
server's copy. Invites are `aisle://join/<code>` links.

## Aisle+

The subscription is bought with StoreKit 2 in the app; the server only trusts it after
checking the App Store's signature.

- `POST /plus/sync` `{"transactions": ["<jws>", …]}`: each StoreKit `jwsRepresentation` of a
  current Aisle+ entitlement. A transaction counts when its certificate chain leads to the
  pinned Apple Root CA - G3, the leaf and intermediate carry Apple's marker extensions,
  the ES256 signature verifies, and it's for `APPLE_BUNDLE_ID` and an Aisle+ product
  (`app.shopaisle.plus.yearly`, `.monthly`). Xcode's local StoreKit test purchases count
  only with `AISLE_PLUS_ALLOW_XCODE=true`. It applies to the sending device and, with a
  session, the account. All rejected → 400. Returns the status below.
- `GET /plus/status` →
  `{"is_plus": false, "expires_at": null, "product_id": null,
    "photo_search": {"used": 2, "limit": 5}, "follow_up": {"used": 0, "limit": 10}}`

Free limits, per UTC day, counted per account when signed in and otherwise per device:
5 photo searches (`/identify`, `/lists/scan`, and `/chat` messages with a photo) and 10
follow-ups (other `/chat` messages). A request only counts when it got an answer.
Over the limit, or for an Aisle+-only feature, the server answers **402**:

```json
{"detail": {"code": "plus_required", "feature": "photo_search", "limit": 5,
            "message": "You've used today's 5 free photo searches. Aisle+ has unlimited."}}
```

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
  `shopping_item_found`, `shopping_item_skipped`, `shopping_finished`, `follow_up_sent`.
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


## AI explanations and store layout

- `POST /search` responses include `explanation` (string | null): two or three
  AI-written sentences on where to find the item at this store. The model is given
  only the resolved fields (department, aisle/section on file, neighbours, confidence,
  availability, source, shopper reports, rough position) and its text is rejected if
  it names an aisle number not on file, uses formatting other than `**bold**`, or is
  empty or too long. Null without an AI key, with `AISLE_AI_EXPLAIN=false`, or when the
  text fails checks; the app then composes its own reply. Cached in memory for 6 hours.
- `GET /stores/{store_id}/layout` → `{store_id, entrance, checkout, zones, approximate}`
  for drawing a schematic map. `entrance`/`checkout` are `{x, y}` or null; each zone is
  `{id, name, x, y, source}` with `x` 0..1 left to right and `y` 0..1 front to back.
  `approximate` is true when any position comes from the store format's template (the
  same for every store of that format), so clients should label the map as typical.
  404 for an unknown store.
