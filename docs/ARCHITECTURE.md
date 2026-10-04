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

Accounts are optional (`backend/app/auth/`, `routers/auth.py`): SMS codes through Twilio
Verify, email codes sent with Resend, and Sign in with Apple and Google, whose ID tokens
are checked against the providers' published keys. Sessions are random bearer tokens
stored only as SHA-256 hashes; the app keeps its token in the Keychain. Only `/me` and
`/auth/signout` need one; every other route is public, and the app still sends an
anonymous install id in `X-Aisle-Device`. The SwiftUI app is the client, so browser CORS is unused.
