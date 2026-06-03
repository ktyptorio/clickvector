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

http_status() {
  local jar="$1"
  shift
  curl -sS -o /tmp/clickvector-query-response.json -w "%{http_code}" -c "$jar" -b "$jar" "$@"
}

mysql_scalar() {
  compose exec -T mysql mysql -N -B -uclickvector -pclickvector clickvector -e "$1" 2>/dev/null
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

wait_readiness() {
  local jar="$1"
  local document_id="$2"
  local expected="$3"
  for _ in $(seq 1 80); do
    readiness="$(api "$jar" "http://localhost:8000/api/documents/${document_id}" | jq -r '.document.readiness')"
    if [[ "$readiness" == "$expected" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for ${document_id} readiness ${expected}; actual=${readiness}" >&2
  return 1
}

assert_status() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "$label expected HTTP $expected, got $actual" >&2
    cat /tmp/clickvector-query-response.json >&2 || true
    exit 1
  fi
}

put_object() {
  local object_key="$1"
  local local_path="$2"
  local container_path="/tmp/clickvector-query-put-$(basename "$local_path")"
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

alice_jar="$(mktemp)"
bob_jar="$(mktemp)"
tmpdir="/tmp/clickvector-query-smoke"
mkdir -p "$tmpdir"

api "$alice_jar" -H 'Content-Type: application/json' \
  -d '{"email":"alice-query@example.com","password":"password123","display_name":"Alice"}' \
  http://localhost:8000/api/auth/register | jq -e '.user.email == "alice-query@example.com"' >/dev/null
api "$bob_jar" -H 'Content-Type: application/json' \
  -d '{"email":"bob-query@example.com","password":"password123","display_name":"Bob"}' \
  http://localhost:8000/api/auth/register | jq -e '.user.email == "bob-query@example.com"' >/dev/null

alice_user_id="$(mysql_scalar "SELECT id FROM users WHERE email='alice-query@example.com'")"

make_pdf "/tmp/alice-ready.pdf" "Alice Ready" "alpha owned ready document chunk should be queryable."
docker cp "$(compose ps -q clickhouse):/tmp/alice-ready.pdf" "$tmpdir/alice-ready.pdf"
alice_ready_upload="$(api "$alice_jar" -F "file=@${tmpdir}/alice-ready.pdf;type=application/pdf" http://localhost:8000/api/documents)"
alice_ready_id="$(echo "$alice_ready_upload" | jq -r '.document.id')"
wait_readiness "$alice_jar" "$alice_ready_id" "ready"

make_pdf "/tmp/bob-ready.pdf" "Bob Ready" "beta other user ready document should stay private."
docker cp "$(compose ps -q clickhouse):/tmp/bob-ready.pdf" "$tmpdir/bob-ready.pdf"
bob_ready_upload="$(api "$bob_jar" -F "file=@${tmpdir}/bob-ready.pdf;type=application/pdf" http://localhost:8000/api/documents)"
bob_ready_id="$(echo "$bob_ready_upload" | jq -r '.document.id')"
wait_readiness "$bob_jar" "$bob_ready_id" "ready"

make_pdf "/tmp/alice-archived.pdf" "Alice Archived" "archived ready document should not be queryable."
docker cp "$(compose ps -q clickhouse):/tmp/alice-archived.pdf" "$tmpdir/alice-archived.pdf"
archived_upload="$(api "$alice_jar" -F "file=@${tmpdir}/alice-archived.pdf;type=application/pdf" http://localhost:8000/api/documents)"
archived_id="$(echo "$archived_upload" | jq -r '.document.id')"
wait_readiness "$alice_jar" "$archived_id" "ready"
api "$alice_jar" -X DELETE "http://localhost:8000/api/documents/${archived_id}" >/dev/null

processing_id="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"
mysql_scalar "INSERT INTO managed_documents (id,user_id,display_name,display_name_overridden,original_filename,latest_object_key,latest_etag,content_type,size_bytes,readiness,created_at,updated_at) VALUES ('${processing_id}','${alice_user_id}','processing.pdf',0,'processing.pdf','users/${alice_user_id}/documents/${processing_id}/processing.pdf','pending-etag','application/pdf',1,'processing',UTC_TIMESTAMP(6),UTC_TIMESTAMP(6))" >/dev/null

failed_id="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"
failed_key="users/${alice_user_id}/documents/${failed_id}/failed.pdf"
failed_path="$tmpdir/failed.pdf"
printf 'not a valid pdf' > "$failed_path"
failed_etag="$(put_object "$failed_key" "$failed_path")"
mysql_scalar "INSERT INTO managed_documents (id,user_id,display_name,display_name_overridden,original_filename,latest_object_key,latest_etag,content_type,size_bytes,readiness,created_at,updated_at) VALUES ('${failed_id}','${alice_user_id}','failed.pdf',0,'failed.pdf','${failed_key}','${failed_etag}','application/pdf',15,'processing',UTC_TIMESTAMP(6),UTC_TIMESTAMP(6))" >/dev/null
trigger_refresh
wait_readiness "$alice_jar" "$failed_id" "failed"

default_query="$(api "$alice_jar" -H 'Content-Type: application/json' -d '{"query":"alpha owned ready document"}' http://localhost:8000/api/query)"
echo "$default_query" | jq -e '.top_k == 10 and (.results | length) >= 1' >/dev/null
echo "$default_query" | jq -e --arg ready "$alice_ready_id" --arg bob "$bob_ready_id" --arg archived "$archived_id" --arg processing "$processing_id" --arg failed "$failed_id" '
  all(.results[]; .document_id == $ready)
  and all(.results[]; has("score") and has("distance") and has("chunk_text") and has("chunk_index") and has("document_display_name") and has("download_url"))
  and all(.results[]; ((has("bucket") or has("object_key") or has("etag")) | not))
  and all(.results[]; .document_id != $bob and .document_id != $archived and .document_id != $processing and .document_id != $failed)
' >/dev/null

top_query="$(api "$alice_jar" -H 'Content-Type: application/json' -d '{"query":"alpha owned ready document","top_k":1}' http://localhost:8000/api/query)"
echo "$top_query" | jq -e '.top_k == 1 and (.results | length) <= 1' >/dev/null

too_large_status="$(http_status "$alice_jar" -H 'Content-Type: application/json' -d '{"query":"alpha","top_k":51}' http://localhost:8000/api/query)"
assert_status "422" "$too_large_status" "top_k over max"
empty_status="$(http_status "$alice_jar" -H 'Content-Type: application/json' -d '{"query":"","top_k":10}' http://localhost:8000/api/query)"
assert_status "422" "$empty_status" "empty query"

bob_query="$(api "$bob_jar" -H 'Content-Type: application/json' -d '{"query":"beta other user ready document","top_k":10}' http://localhost:8000/api/query)"
echo "$bob_query" | jq -e --arg bob "$bob_ready_id" --arg alice "$alice_ready_id" '(.results | length) >= 1 and all(.results[]; .document_id == $bob and .document_id != $alice)' >/dev/null

echo "Query smoke test passed."
