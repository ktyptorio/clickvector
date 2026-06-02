# ClickVector

End-to-end MinIO to ClickHouse document ingestion using a ClickHouse refreshable materialized view and executable Python runner.

## Run

Export an OpenAI API key, then start the stack:

```sh
export OPENAI_API_KEY=...
docker compose up -d --build --wait
```

The compose stack has two services:

- `minio`: object storage for PDF/DOCX source documents
- `clickhouse`: ClickHouse plus the Python executable runner and schema init

MinIO console is available at `http://localhost:9001` with `minioadmin` / `minioadmin`.
ClickHouse HTTP is available at `http://localhost:8123`.

## Smoke Test

```sh
export OPENAI_API_KEY=...
./scripts/smoke_test.sh
```

The smoke test:

1. Starts the two-service compose stack.
2. Uploads one initial PDF to MinIO.
3. Triggers ingestion through the refreshable materialized view.
4. Uploads two more PDFs and ingests them.
5. Updates the first PDF and ingests the new etag as a new Document Version.
6. Prints ingestion records, chunk counts, run summaries, version counts, and latest completed object count.

## Important Files

- `docker-compose.yml`: two-service runtime.
- `clickhouse/initdb/001_document_pipeline.sql`: ClickHouse schema, vector index, and refreshable materialized view.
- `pipeline/ingest_runner.py`: executable runner called by ClickHouse.
- `scripts/seed_minio.py`: PDF seed/update helper.
- `scripts/smoke_test.sh`: end-to-end verification.
- `docs/design/ingestion-pipeline.md`: design summary.
