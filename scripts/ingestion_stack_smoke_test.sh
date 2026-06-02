#!/usr/bin/env bash
set -euo pipefail

compose() {
  docker compose -f docker-compose.pipeline.yml "$@"
}

compose up -d --build --wait

compose exec -T minio mc ready local >/dev/null
compose exec -T clickhouse clickhouse-client --password clickhouse --database document_pipeline --query "SELECT 1" >/dev/null
compose exec -T clickhouse clickhouse-client --password clickhouse --database document_pipeline --query "SELECT count() FROM system.tables WHERE database = 'document_pipeline' AND name IN ('document_ingestions', 'document_chunks', 'ingestion_runs')" | grep -q '^3$'

echo "MinIO and ClickHouse ingestion stack is healthy."
