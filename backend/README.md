# Aisle backend

Python 3.10+ / FastAPI / SQLAlchemy 2 / Alembic / Pydantic 2.
Store discovery, item search, feedback, list parsing, routing, and analytics.
The full contract is in `docs/API.md`; tables are in `docs/DATA_MODEL.md`.

## Setup

Run from the repository root:

```sh
python3 -m venv backend/.venv
source backend/.venv/bin/activate
pip install -r backend/requirements.txt
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

## API

Interactive API documentation: <http://127.0.0.1:8000/docs>.

- `GET /health` → `{"status":"ok"}`. Liveness only; no database access.
- `GET /stores/nearby?lat=39.9526&lon=-75.1652&limit=20` →
  `{"stores":[...],"message":null}`. Stores include `distance_miles` and are
  ordered by great-circle distance, with store ID breaking ties.
- Missing either coordinate → `{"stores":[],"message":"Provide both lat and lon to find nearby stores."}`.
  This succeeds without querying the database.
- `GET /stores/search?q=Market` → an array matching store name, retailer name,
  or address by case-insensitive substring. Surrounding whitespace is ignored;
  `%` and `_` are literal characters. A whitespace-only query returns `[]`;
  a missing or empty `q` returns 422.
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

Import real product locations (the only source of aisle text):

```sh
python -m backend.app.import_locations locations.csv
```

## Current limitations

Seed data is representative demo data with approximate coordinates, not a verified
or live store directory. Provider place IDs and store numbers remain null.
Distances are straight-line miles, not driving distances. Nearby discovery sorts
all stores in memory and search has no pagination; this is appropriate for the
small Milestone 1 directory and will need indexing/pagination for larger datasets.
Zone layouts and coordinates are per-format templates, not real floor plans. No real
aisle data is seeded.
