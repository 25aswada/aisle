# Aisle backend

Python 3.10+ / FastAPI / SQLAlchemy 2 / Alembic / Pydantic 2.
Store discovery, item search, feedback, list parsing, routing, and analytics.
The full contract is in `docs/API.md`; tables are in `docs/DATA_MODEL.md`.

## Setup

Run from the repository root:

```sh
python3 -m venv backend/.venv
source backend/.venv/bin/activate
pip install -r backend/requirements-dev.txt
cp backend/.env.example backend/.env
docker compose up -d postgres
alembic -c backend/alembic.ini upgrade head
python -m backend.app.seed
uvicorn backend.app.main:app --reload
```

`DATABASE_URL` defaults to PostgreSQL using psycopg 3. An exported
`DATABASE_URL` overrides `backend/.env`, regardless of working directory.
The example credentials are for local development; configure deployment credentials
through the environment. Standard `postgresql://` and `postgres://` URLs are
also accepted. Tables are managed by Alembic, not created during app startup.
Seeding is explicit and safe to run repeatedly in serial; it inserts missing
representative stores without replacing existing records.

If Docker is unavailable, use SQLite for local development:

```sh
export DATABASE_URL="sqlite:///$(pwd)/backend/local.db"
alembic -c backend/alembic.ini upgrade head
python -m backend.app.seed
uvicorn backend.app.main:app --reload
```

## Deploying (Heroku)

The Heroku app `aisle-api` runs this folder on its own, with Heroku Postgres as
`DATABASE_URL` (its `postgres://` form is normalized to psycopg 3 in `config.py`).
From the repo root:

```bash
git subtree push --prefix backend heroku main
```

`Procfile` runs `alembic upgrade head` as the release step and serves `app.main:app`
with uvicorn; `.python-version` pins Python 3.13. Inside the deployed folder the
package is `app`, not `backend.app` (`alembic/env.py` handles both). Seed a new
database once with `heroku run python -m app.seed -a aisle-api`. Secrets are set with
`heroku config:set`, never committed.

### Sign in with Apple key (required for account deletion)

App Review requires deleting an account to revoke its Sign in with Apple, and the server
can only do that with a Sign in with Apple key. Until it's set, deletion still works but
logs an error for each Apple account, and the revocation can't happen.

1. In the Apple Developer portal: Certificates, Identifiers & Profiles → Keys → **+**.
   Name it (e.g. "Aisle Sign in with Apple"), tick **Sign in with Apple**, click
   Configure and choose the primary App ID `app.shopaisle.aisle`. Save, Continue, Register.
2. Download the `.p8` file (Apple allows this only once) and note the **Key ID** shown
   with it. The Team ID is `983N58VUTZ`.
3. Set the three config vars (the private key is the file's whole contents, line breaks
   included):

   ```bash
   heroku config:set -a aisle-api APPLE_TEAM_ID=983N58VUTZ APPLE_SIGNIN_KEY_ID=<Key ID> \
     APPLE_SIGNIN_PRIVATE_KEY="$(cat AuthKey_<Key ID>.p8)"
   ```

4. Notifications: Certificates, Identifiers & Profiles → Identifiers → the App ID
   `app.shopaisle.aisle` → Sign in with Apple → Edit → **Server-to-Server Notification
   Endpoint**: `https://aisle-api-db30672cd6aa.herokuapp.com/auth/apple/notifications`.
   Apple then tells the server when someone stops using their Apple ID with Aisle or
   deletes their Apple ID.

Deletions made before the key was set can't be revoked afterwards: Apple's one-time codes
last five minutes, and cleanup logs an error when it gives up on one.

## API

Interactive API documentation: <http://127.0.0.1:8000/docs>.

- `GET /health` → `{"status":"ok"}`. Liveness only; no database access.
- `GET /stores/nearby?lat=39.9526&lon=-75.1652&limit=20` →
  `{"stores":[...],"message":null}`. Stores include `distance_miles` and are
  ordered by great-circle distance, with store ID breaking ties.
- Missing either coordinate → `{"stores":[],"message":"Provide both lat and lon to find nearby stores."}`.
  This succeeds without querying the database.
- `GET /stores/search?q=Market` → up to `limit` (default 50) stores whose name,
  retailer name or address contain every word of `q`, case-insensitively; with `lat`
  and `lon`, nearest first with `distance_miles`. `%` and `_` are literal characters.
  A whitespace-only query returns `[]`; a missing or empty `q` returns 422.
- `GET /stores/{store_id}` → one store, or 404 if absent.

Stores expose `id`, `retailer_id`, `name`, `address`, `latitude`, `longitude`,
nullable `external_place_id` and `store_number`, `retailer_logo_url` (a logo.dev image
when `LOGO_DEV_PUBLISHABLE_KEY` is set, else null), plus nested `retailer` with
`id`, `name` and nullable `domain`. Latitude must be between -90 and 90, longitude between -180
and 180, and limit between 1 and 100 (default 20). Invalid parameters return 422.

## Tests

With the virtual environment activated, from the repository root:

```sh
pytest
```

Pytest discovers `tests/backend` from the repo root; to explicitly use backend
configuration, run `pytest -c backend/pyproject.toml`. Each database test uses
an isolated temporary SQLite database initialized through Alembic. Tests never
connect to the configured production database and need neither Docker nor Postgres.
They cover health, nearby ordering/distances/limits, missing coordinates,
search, details/404, invalid input, seed idempotence, and migration round trips.

## Item search and AI

Without `ANTHROPIC_API_KEY`, search uses the deterministic catalog fallback; nothing
blocks. With a key, Claude (`AISLE_AI_MODEL`, default `claude-opus-5-5`) handles
queries the catalog can't classify (`AISLE_AI_STRATEGY=catalog_first`) or answers first
(`model_first`). To use OpenAI instead, set `OPENAI_API_KEY` (and `AISLE_AI_PROVIDER=openai`
if an Anthropic key is also set); the model defaults to `gpt-6-luna`. Check provider quality with:

```sh
python -m backend.app.ai.evaluate             # model if a key is set
python -m backend.app.ai.evaluate --fallback  # deterministic only
```

## Real stores

`import_stores` loads the US locations of about 70 major chains (Walmart, Target,
Kroger, Costco, Giant Eagle, Publix, CVS, Home Depot…, listed in `CHAINS`) from
OpenStreetMap through the Overpass API. A store is imported only when OSM ties it to the
chain's Wikidata ID, and gas stations, pharmacy counters and auto centers that share the
chain's tag are left out. Each chain's stores get its store map: a researched layout
for the chains in `ai/chain_layouts.py`, otherwise their store format's template, copied
the first time a store is used.

```sh
python -m backend.app.import_stores --save stores.json     # fetch all chains (~15 min), then load
python -m backend.app.import_stores --from-file stores.json --dry-run
python -m backend.app.import_stores --chain "Giant Eagle" --bbox 41.0,-82.0,41.6,-81.3
```

Re-running updates stores in place (matched by OSM ID, store number, or the same chain
within 150 m), so store IDs and shoppers' reports survive. Stores no longer in OSM are
listed and only deleted with `--prune`. To load Heroku, run it locally against the
production database: `DATABASE_URL=$(heroku config:get DATABASE_URL -a aisle-api)
python -m backend.app.import_stores --from-file stores.json`. The data is
© OpenStreetMap contributors (ODbL); the app's store picker carries that credit.

Import real product locations (the only source of aisle text):

```sh
python -m backend.app.import_locations locations.csv
```

## Current limitations

Seed data is representative demo data with approximate coordinates; real stores come
from `import_stores`, and are only as complete as OpenStreetMap (stores OSM lacks, or
has without an address, are missing). Distances are straight-line miles, not driving
distances.
Zone layouts and coordinates are per-format templates, not real floor plans. No real
aisle data is seeded.
