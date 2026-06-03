#!/usr/bin/env bash
set -euo pipefail

compose() {
  docker compose "$@"
}

api() {
  local jar="$1"
  shift
  curl -fsS -c "$jar" -b "$jar" "$@"
}

mysql_scalar() {
  compose exec -T mysql mysql -N -B -uclickvector -pclickvector clickvector -e "$1" 2>/dev/null
}

ch_scalar() {
  compose exec -T clickhouse clickhouse-client --password clickhouse --database document_pipeline --query "$1" | tr -d '[:space:]'
}

make_pdf() {
  local output="$1"
  local title="$2"
  local body="$3"
  compose exec -T clickhouse /opt/document-pipeline/.venv/bin/python - "$output" "$title" "$body" <<'PY'
import sys
from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas

path, title, body = sys.argv[1], sys.argv[2], sys.argv[3]
pdf = canvas.Canvas(path, pagesize=letter)
pdf.setFont("Helvetica-Bold", 14)
pdf.drawString(72, 720, title)
pdf.setFont("Helvetica", 10)
pdf.drawString(72, 690, body)
pdf.save()
PY
}

wait_document_readiness() {
  local jar="$1"
  local document_id="$2"
  local expected="$3"
  local actual=""
  for _ in $(seq 1 80); do
    actual="$(api "$jar" "http://localhost:8000/api/documents/${document_id}" | jq -r '.document.readiness')"
    if [[ "$actual" == "$expected" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for document ${document_id} readiness ${expected}; actual=${actual}" >&2
  api "$jar" "http://localhost:8000/api/documents/${document_id}" | jq . >&2
  return 1
}

put_object() {
  local object_key="$1"
  local local_path="$2"
  local container_path="/tmp/clickvector-put-object-$(basename "$local_path")"
  docker cp "$local_path" "$(compose ps -q backend):${container_path}"
  compose exec -T backend python - "$object_key" "$container_path" <<'PY'
import os
import sys
from pathlib import Path
from minio import Minio

object_key, local_path = sys.argv[1], sys.argv[2]
client = Minio(
    os.environ["MINIO_ENDPOINT"],
    access_key=os.environ["MINIO_ACCESS_KEY"],
    secret_key=os.environ["MINIO_SECRET_KEY"],
    secure=os.environ.get("MINIO_SECURE", "false").lower() == "true",
)
bucket = os.environ["MINIO_BUCKET"]
if not client.bucket_exists(bucket):
    client.make_bucket(bucket)
content_type = "application/pdf" if Path(object_key).suffix.lower() == ".pdf" else "application/octet-stream"
client.fput_object(bucket, object_key, local_path, content_type=content_type)
print((client.stat_object(bucket, object_key).etag or "").strip('"'))
PY
}

trigger_refresh() {
  compose exec -T clickhouse clickhouse-client --password clickhouse --database document_pipeline --query "SYSTEM REFRESH VIEW ingestion_runs_mv" >/dev/null
}

compose down -v --remove-orphans
compose up -d --build --wait mysql minio clickhouse backend frontend

ingestion_user_columns="$(ch_scalar "SELECT count() FROM system.columns WHERE database='document_pipeline' AND table='document_ingestions' AND name IN ('user_id', 'document_id')")"
chunk_user_columns="$(ch_scalar "SELECT count() FROM system.columns WHERE database='document_pipeline' AND table='document_chunks' AND name IN ('user_id', 'document_id')")"
if [[ "$ingestion_user_columns" != "2" || "$chunk_user_columns" != "2" ]]; then
  echo "ClickHouse ownership columns are missing" >&2
  exit 1
fi

jar="$(mktemp)"
tmpdir="/tmp/clickvector-ingestion-ownership-smoke"
mkdir -p "$tmpdir"

api "$jar" -H 'Content-Type: application/json' \
  -d '{"email":"owner@example.com","password":"password123","display_name":"Owner"}' \
  http://localhost:8000/api/auth/register | jq -e '.user.email == "owner@example.com"' >/dev/null
user_id="$(mysql_scalar "SELECT id FROM users WHERE email='owner@example.com'")"

make_pdf "/tmp/valid.pdf" "Valid Ownership" "This valid document should become ready after ClickHouse ingestion sync."
docker cp "$(compose ps -q clickhouse):/tmp/valid.pdf" "$tmpdir/valid.pdf"
valid_upload="$(api "$jar" -F "file=@${tmpdir}/valid.pdf;type=application/pdf" http://localhost:8000/api/documents)"
valid_id="$(echo "$valid_upload" | jq -r '.document.id')"
wait_document_readiness "$jar" "$valid_id" "ready"
valid_ingestions="$(ch_scalar "SELECT count() FROM document_ingestions FINAL WHERE user_id='${user_id}' AND document_id='${valid_id}' AND status='completed'")"
valid_chunks="$(ch_scalar "SELECT count() FROM document_chunks WHERE user_id='${user_id}' AND document_id='${valid_id}'")"
if [[ "$valid_ingestions" != "1" || "$valid_chunks" == "0" ]]; then
  echo "valid document did not ingest with ownership fields" >&2
  exit 1
fi

corrupt_id="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"
corrupt_key="users/${user_id}/documents/${corrupt_id}/corrupt.pdf"
corrupt_path="$tmpdir/corrupt.pdf"
printf 'not a real pdf' > "$corrupt_path"
corrupt_etag="$(put_object "$corrupt_key" "$corrupt_path")"
mysql_scalar "INSERT INTO managed_documents (id,user_id,display_name,display_name_overridden,original_filename,latest_object_key,latest_etag,content_type,size_bytes,readiness,created_at,updated_at) VALUES ('${corrupt_id}','${user_id}','corrupt.pdf',0,'corrupt.pdf','${corrupt_key}','${corrupt_etag}','application/pdf',14,'processing',UTC_TIMESTAMP(6),UTC_TIMESTAMP(6))" >/dev/null
trigger_refresh
wait_document_readiness "$jar" "$corrupt_id" "failed"
failed_ingestions="$(ch_scalar "SELECT count() FROM document_ingestions FINAL WHERE user_id='${user_id}' AND document_id='${corrupt_id}' AND status='failed'")"
if [[ "$failed_ingestions" != "1" ]]; then
  echo "corrupt document did not map to failed readiness" >&2
  exit 1
fi

archived_id="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"
archived_key="users/${user_id}/documents/${archived_id}/archived.pdf"
make_pdf "/tmp/archived.pdf" "Archived" "Archived managed document should be skipped."
docker cp "$(compose ps -q clickhouse):/tmp/archived.pdf" "$tmpdir/archived.pdf"
archived_etag="$(put_object "$archived_key" "$tmpdir/archived.pdf")"
mysql_scalar "INSERT INTO managed_documents (id,user_id,display_name,display_name_overridden,original_filename,latest_object_key,latest_etag,content_type,size_bytes,readiness,created_at,updated_at,archived_at) VALUES ('${archived_id}','${user_id}','archived.pdf',0,'archived.pdf','${archived_key}','${archived_etag}','application/pdf',100,'archived',UTC_TIMESTAMP(6),UTC_TIMESTAMP(6),UTC_TIMESTAMP(6))" >/dev/null

invalid_id="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"
invalid_key="users/${user_id}/documents/${invalid_id}/orphan.pdf"
put_object "$invalid_key" "$tmpdir/archived.pdf" >/dev/null
trigger_refresh
sleep 2

archived_ingestions="$(ch_scalar "SELECT count() FROM document_ingestions FINAL WHERE user_id='${user_id}' AND document_id='${archived_id}'")"
invalid_ingestions="$(ch_scalar "SELECT count() FROM document_ingestions FINAL WHERE object_key='${invalid_key}'")"
if [[ "$archived_ingestions" != "0" || "$invalid_ingestions" != "0" ]]; then
  echo "archived or invalid objects were ingested unexpectedly" >&2
  exit 1
fi

api "$jar" "http://localhost:8000/api/documents?readiness=ready&limit=10&offset=0" | jq -e --arg id "$valid_id" '.items[] | select(.id == $id and .readiness == "ready")' >/dev/null
api "$jar" "http://localhost:8000/api/documents?readiness=failed&limit=10&offset=0" | jq -e --arg id "$corrupt_id" '.items[] | select(.id == $id and .readiness == "failed")' >/dev/null

echo "Ingestion ownership smoke test passed."
