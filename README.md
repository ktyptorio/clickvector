# ClickVector

ClickVector has two local runtime contexts:

- ClickVector UI app: MinIO, ClickHouse, MySQL, backend, and frontend.
- ClickVector pipeline standalone: MinIO and ClickHouse only, matching the first ingestion pipeline context.

## Run

### ClickVector UI app

For local app development, mock embeddings are enabled by default so the stack can be tested without an OpenAI key:

```sh
docker compose up -d --build --wait
```

To use OpenAI embeddings instead:

```sh
export OPENAI_API_KEY=...
MOCK_EMBEDDINGS=false docker compose up -d --build --wait
```

Services:

- `frontend`: React app at `http://localhost:5173`
- `backend`: FastAPI app at `http://localhost:8000`
- `mysql`: users, sessions, and Managed Document metadata
- `minio`: object storage for uploaded originals
- `clickhouse`: app-aware ingestion records, chunk vectors, and refreshable ingestion scheduler

MinIO console is available at `http://localhost:9001` with `minioadmin` / `minioadmin`.
ClickHouse HTTP is available at `http://localhost:8123`.

### ClickVector pipeline standalone

The standalone pipeline compose is intentionally separate from the UI app. It only starts MinIO and ClickHouse, uses the standalone ClickHouse schema without `user_id` or `document_id`, and runs a standalone ingestion script that does not read MySQL or backend metadata.

```sh
MOCK_EMBEDDINGS=true docker compose -f docker-compose.pipeline.yml up -d --build --wait
```

To use OpenAI embeddings instead:

```sh
export OPENAI_API_KEY=...
MOCK_EMBEDDINGS=false docker compose -f docker-compose.pipeline.yml up -d --build --wait
```

Standalone services:

- `minio`: object storage for PDF/DOCX source documents
- `clickhouse`: ClickHouse plus the standalone Python executable runner and standalone schema init

The standalone compose uses the same host ports as the UI app compose. Stop one context before starting the other.

## Smoke Test

```sh
MOCK_EMBEDDINGS=true ./scripts/smoke_test.sh
```

The smoke test starts the five-service stack, registers users, uploads PDFs, replaces one PDF, archives another, runs a query, verifies per-user isolation, and prints MySQL/ClickHouse summaries.

For a narrower MinIO + ClickHouse standalone health check:

```sh
MOCK_EMBEDDINGS=true ./scripts/ingestion_stack_smoke_test.sh
```

For the original-style standalone ingestion flow:

```sh
MOCK_EMBEDDINGS=true ./scripts/pipeline_smoke_test.sh
```

For auth/session coverage:

```sh
MOCK_EMBEDDINGS=true ./scripts/auth_smoke_test.sh
```

The auth smoke test covers lowercase email normalization, unique email rejection, Argon2id password storage, 1-hour MySQL-backed sessions, current-user lookup, invalid credentials, expired sessions, and logout revocation.

## MySQL Migrations

The backend applies MySQL schema migrations on startup before serving traffic. The same migration path can be run manually:

```sh
docker compose exec backend python -m app.migrate
```

Current migrations create `users`, `sessions`, and `managed_documents`.

## Important Files

- `docker-compose.yml`: five-service UI app runtime.
- `docker-compose.pipeline.yml`: two-service standalone pipeline runtime.
- `backend/app/main.py`: FastAPI backend for auth, documents, readiness sync, and query.
- `backend/app/migrate.py`: manual MySQL migration entrypoint.
- `frontend/src/App.jsx`: React app shell for Documents and Query.
- `clickhouse/initdb/001_document_pipeline.sql`: app-aware ClickHouse schema, vector index, and refreshable materialized view.
- `clickhouse/standalone/initdb/001_document_pipeline.sql`: standalone ClickHouse schema for MinIO + ClickHouse only.
- `pipeline/ingest_runner.py`: app-aware Python executable runner called by ClickHouse.
- `pipeline/ingest_runner_standalone.py`: standalone Python executable runner called by ClickHouse.
- `scripts/app_smoke_test.sh`: end-to-end app verification.
- `scripts/auth_smoke_test.sh`: auth/session verification.
- `scripts/ingestion_stack_smoke_test.sh`: MinIO + ClickHouse stack verification.
- `scripts/pipeline_smoke_test.sh`: standalone MinIO + ClickHouse ingestion verification.
