# Aisle architecture

Aisle helps people find items inside physical stores. These documents cover Milestone 0 and Milestone 1: the monorepo, the API, the database, the iOS shell, and store discovery.

Item search is not in this milestone.

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

Milestone 0 and Milestone 1 stop at store discovery. The HTTP API has no item, aisle, list, or route routes. See `API.md` for the four routes and `DATA_MODEL.md` for the two tables.

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

Stores are loaded into Postgres outside the HTTP API. This milestone has no write routes.

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

The four routes are public reads. This milestone has no accounts, tokens, or sessions. The SwiftUI app is the client, so browser CORS is unused.
