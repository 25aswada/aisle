# Aisle architecture

Aisle helps people find items inside physical stores. These documents describe the monorepo, the API, the database, the iOS app, store discovery, and item search.

## Milestone 0

- One git monorepo.
- FastAPI service.
- Postgres database.
- SwiftUI app.
- `GET /health` returns `{"status":"ok"}`.
- GitHub Actions runs backend pytest when `backend/` is present.

## Milestone 1

- Retailer and store records in Postgres.
- Nearby store search from a latitude and longitude.
- Manual store search by text.
- Device location is optional. Manual search works when location is unavailable or denied.

## Milestone 2: item search

- Find screen search field calls `POST /search` with the query and selected store.
- `backend/app/ai/intent.py` parses the query (filler words, quantity, modifiers) and
  matches the catalog in `backend/app/ai/catalog.py`.
- Location reasoning maps the category to a department in the store's layout: a
  researched chain layout (12 chains, `ai/chain_layouts.py`) or a generic store-format
  template (warehouse club, supercenter, pharmacy, home improvement, grocery).
- AI provider (`backend/app/ai/providers.py`): Claude via the Anthropic SDK when
  `ANTHROPIC_API_KEY` is set, or an OpenAI model (default `gpt-6-luna`) when
  `OPENAI_API_KEY` is set. `AISLE_AI_PROVIDER` (`auto`, `anthropic`, `openai`) picks one when
  both keys are present; `auto` prefers Anthropic. The model must pick a department from the layout's list
  through a JSON schema, so it cannot invent aisle numbers. Its output is validated again
  server-side. With the default `AISLE_AI_STRATEGY=catalog_first` the model only handles
  queries the catalog can't classify. Without a key, or on any provider error, the
  deterministic fallback answers.
- With a key, the model also writes each result's "where to find it" reply
  (`ai/explain.py`), answering in its own words from what it knows about the chain, like a
  chatbot. Only real data for the store (product data, aisle numbers, shopper reports) goes
  in with the question; layout guesses don't. The reply is shown as written; the app uses
  its own wording only when there is none.
- Eval cases live in `backend/app/ai/eval_cases.json`. Run
  `python -m backend.app.ai.evaluate` (model if a key is set) or `--fallback`.

## Milestones 3–7

- **3: resolver.** Categories, product concepts, store zones, and product locations in the
  database. Source priority: verified/retailer rows > shopper consensus > verified zone >
  model > catalog fallback. Database rows always beat the model.
- **4: feedback.** Found it / Not here / corrections become `location_observations`;
  every search is a `search_event`.
- **5: lists.** `POST /lists/parse` splits text into items; the list lives on the device.
- **6: routing.** Zones have floor-plan coordinates; `POST /route` orders stops from
  entrance to checkout; the app's Start Shopping mode walks them with Found / Skip.
- **7: polish.** Loading skeletons, offline/timeout messages, a JSON 500 handler, light/dark
  themes with an accent that adapts, Dynamic Type layouts, recent searches, result and AI
  caching, and opt-out anonymous analytics (`POST /events`).

See `API.md` for routes and `DATA_MODEL.md` for tables.

## Monorepo

```
aisle/
  backend/                  FastAPI application and pytest suite
  ios/                      SwiftUI application
  docs/
    ARCHITECTURE.md
    DATA_MODEL.md
    API.md
  .github/workflows/ci.yml
```

`docs/` and `.github/workflows/` hold the architecture contract and CI. Application code belongs in `backend/` and `ios/`.

## Runtime

| Piece | Role in this milestone |
| --- | --- |
| SwiftUI app | Store discovery. Calls the API. Location permission is optional. |
| FastAPI | Serves the routes in `API.md`. Reads retailers and stores from Postgres. |
| Postgres | System of record for retailers and stores. |

Local API origin: `http://127.0.0.1:8000`.

The API process reads `DATABASE_URL` for its Postgres connection.

`GET /health` reports that the API process is up. It returns `{"status":"ok"}` and does not query Postgres.

## Store discovery

1. The app may request location. The person can deny it and continue.
2. With coordinates, the app calls `GET /stores/nearby?lat=&lon=&limit=`.
3. With or without coordinates, the app calls `GET /stores/search?q=` for manual search.
4. Choosing a store loads `GET /stores/{store_id}`.

Nearby results include `distance_miles`. Search results and store detail set `distance_miles` to null, because those requests carry no origin.

Stores are loaded into Postgres outside the HTTP API (seed script).

Nearby ordering uses the haversine formula on `stores.latitude` and `stores.longitude`, with an Earth radius of 3958.8 miles. Postgres extensions such as PostGIS are not required.

## CI

`.github/workflows/ci.yml` is the only workflow. It has one job, `backend-pytest`.

- Every push and pull request checks out the repo.
- When `backend/` is absent, the job succeeds and skips pytest.
- When `backend/` is present, the job uses Python 3.12, installs dependencies, and runs `python -m pytest` with working directory `backend/`.
- Install `backend/requirements.txt` when that file exists.
- Install `backend/` in editable mode when `backend/pyproject.toml` exists.
- Install `pytest` for the job even if the project files already include it.

Pytest discovery is the default: files named `test_*.py` or `*_test.py` under `backend/`. The workflow does not start an iOS simulator.

## Access

The app requires an account (`backend/app/auth/`, `routers/auth.py`): onboarding ends at
sign-up and the tabs open only when signed in. Sign-in is by SMS code through Twilio
Verify, email code sent with Resend, or Sign in with Apple and Google, whose ID tokens are
checked against the providers' published keys. Sessions are random bearer tokens stored
only as SHA-256 hashes; the app keeps its token in the Keychain. Follow-ups, photo search,
list scanning, reports and shared lists need a session on the server; store lookups,
`/search` and `/route` stay public. The app also sends a random install id in
`X-Aisle-Device`, and makes a new one on sign-out and account deletion. The SwiftUI app is
the client, so browser CORS is unused.

Deleting an account (`DELETE /me`) removes it, its sign-ins, its Aisle+ link and its usage
counts on the server; on the phone, `LocalAccountData` erases lists, history, stats, the
chosen store and saved maps, and onboarding starts over. When a different account signs
in on the same phone, the previous account's local data is erased too.

## Operations

- Logs go to stdout at `AISLE_LOG_LEVEL` (INFO), as `LEVEL logger: message`, with no
  personal data; each AI call logs its model, tokens and cost.
- Errors go to Sentry when `SENTRY_DSN` is set, scrubbed of bodies, query strings, cookies,
  IPs and most headers (`backend/app/monitoring.py`).
- AI spend is capped per day in dollars (`AISLE_AI_BUDGET_USD_PER_DAY`, `backend/app/ai/budget.py`).

## Aisle+

The subscription is bought with StoreKit 2 (`ios/Aisle/Account/PlusStore.swift`), stamped
with the account's `plus_token` as its `appAccountToken`, so it belongs to that Aisle
account rather than the Apple ID. The app sends each current transaction's signed JWS to
`POST /plus/sync`; the server checks it against the pinned Apple root
(`backend/app/plus/appstore.py`) and the token, and only then lifts limits
(`backend/app/plus/access.py`). What it covers, and where it's enforced:

| Feature | Free | Aisle+ | Enforced |
| --- | --- | --- | --- |
| Photo searches (`/identify`, `/lists/scan`, photo `/chat`) | 3 a day | Unlimited (fair use: 50 a day) | Server, 402 `photo_search` |
| Follow-up questions (`/chat`) | 5 a day | Unlimited (fair use: 100 a day) | Server, 402 `follow_up` |
| AI answers on searches and routes (`/search`, `/route`) | 20 a day, then Aisle's own answers | Unlimited (fair use: 300 a day) | Server |
| Lists | 1 | Unlimited | App |
| Shared family lists (`/lists`) | Join only | Share | Server, 402 `shared_lists` |
| Multi-store trips (`/route/multi`) | — | 2–4 stores | Server, 402 `multi_store` |
| Offline store maps | — | ✓ | App (`ios/Aisle/Offline/`) |

Offline maps are an `AisleAPI` wrapper (`OfflineAwareAPI`). While Aisle+ is on, it saves
each store's layout, the spot of every item routed or searched there, and search answers
under Application Support. When a request fails for lack of a connection (offline,
timeout, transport, 5xx; never a 4xx such as 402), it answers from what's saved; a route
is then planned on the phone from the saved spots, nearest-first from the entrance.

Every 402 carries `{"code": "plus_required", "feature", "message"}`; the app turns it
into `APIError.plusRequired` and opens the Aisle+ page with the message.
