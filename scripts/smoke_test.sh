#!/usr/bin/env bash
set -euo pipefail

compose() {
  docker compose "$@"
}

query() {
  compose exec -T clickhouse clickhouse-client --password clickhouse --database document_pipeline --query "$1"
}

refresh() {
  query "SYSTEM REFRESH VIEW ingestion_runs_mv"
}

wait_completed_versions() {
  local expected="$1"
  local actual="0"
  for _ in $(seq 1 60); do
    actual="$(query "SELECT count() FROM document_ingestions FINAL WHERE status = 'completed'" | tr -d '[:space:]')"
    processing="$(query "SELECT count() FROM document_ingestions FINAL WHERE status = 'processing'" | tr -d '[:space:]')"
    if [[ "$actual" == "$expected" && "$processing" == "0" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for $expected completed versions; actual=$actual" >&2
  return 1
}

print_counts() {
  echo "document_ingestions"
  query "SELECT bucket, object_key, etag, status, attempt_count, chunk_count FROM document_ingestions FINAL ORDER BY object_key, source_last_modified FORMAT PrettyCompact"
  echo "document_chunks"
  query "SELECT object_key, etag, count() AS chunks FROM document_chunks GROUP BY object_key, etag ORDER BY object_key, etag FORMAT PrettyCompact"
  echo "ingestion_runs"
  query "SELECT status, scanned_count, processed_count, skipped_count, failed_count FROM ingestion_runs ORDER BY started_at FORMAT PrettyCompact"
}

compose up -d --build --wait

echo "seed initial PDF"
compose exec -T clickhouse /opt/document-pipeline/.venv/bin/python /opt/document-pipeline/seed_minio.py initial
refresh
wait_completed_versions 1

echo "add PDFs"
compose exec -T clickhouse /opt/document-pipeline/.venv/bin/python /opt/document-pipeline/seed_minio.py add
refresh
wait_completed_versions 3

echo "update one PDF"
compose exec -T clickhouse /opt/document-pipeline/.venv/bin/python /opt/document-pipeline/seed_minio.py update
refresh
wait_completed_versions 4

print_counts

query "SELECT object_key, countDistinct(etag) AS versions FROM document_ingestions FINAL GROUP BY object_key ORDER BY object_key FORMAT PrettyCompact"
query "SELECT count() AS latest_completed_objects FROM (SELECT bucket, object_key, argMax(document_version_id, (source_last_modified, completed_at, etag)) AS document_version_id FROM document_ingestions FINAL WHERE status = 'completed' GROUP BY bucket, object_key) FORMAT PrettyCompact"
