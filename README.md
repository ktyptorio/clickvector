# ClickVector

ClickVector is a small document search app that stores user-owned PDF/DOCX files in MinIO, ingests text chunks into ClickHouse vectors, and exposes a web UI for document management and semantic query.

## Run

For local development, mock embeddings are enabled by default so the stack can be tested without an OpenAI key:

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
- `clickhouse`: ingestion records, chunk vectors, and refreshable ingestion scheduler

MinIO console is available at `http://localhost:9001` with `minioadmin` / `minioadmin`.
ClickHouse HTTP is available at `http://localhost:8123`.

## Smoke Test

```sh
MOCK_EMBEDDINGS=true ./scripts/smoke_test.sh
```

The smoke test starts the five-service stack, registers users, uploads PDFs, replaces one PDF, archives another, runs a query, verifies per-user isolation, and prints MySQL/ClickHouse summaries.

## Important Files

- `docker-compose.yml`: five-service runtime.
- `backend/app/main.py`: FastAPI backend for auth, documents, readiness sync, and query.
- `frontend/src/App.jsx`: React app shell for Documents and Query.
- `clickhouse/initdb/001_document_pipeline.sql`: ClickHouse schema, vector index, and refreshable materialized view.
- `pipeline/ingest_runner.py`: Python executable runner called by ClickHouse.
- `scripts/app_smoke_test.sh`: end-to-end app verification.
