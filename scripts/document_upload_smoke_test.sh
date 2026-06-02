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
  curl -sS -o /tmp/clickvector-upload-response.json -w "%{http_code}" -c "$jar" -b "$jar" "$@"
}

mysql_json() {
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

assert_status() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "$label expected HTTP $expected, got $actual" >&2
    cat /tmp/clickvector-upload-response.json >&2 || true
    exit 1
  fi
}

compose down -v --remove-orphans
compose up -d --build --wait mysql minio clickhouse backend frontend

jar="$(mktemp)"
tmpdir="/tmp/clickvector-upload-smoke"
mkdir -p "$tmpdir"

api "$jar" -H 'Content-Type: application/json' \
  -d '{"email":"uploader@example.com","password":"password123","display_name":"Uploader"}' \
  http://localhost:8000/api/auth/register | jq -e '.user.email == "uploader@example.com"' >/dev/null

make_pdf "/tmp/duplicate.pdf" "Duplicate Name" "First upload creates the first Managed Document."
docker cp "$(compose ps -q clickhouse):/tmp/duplicate.pdf" "$tmpdir/duplicate.pdf"

first_upload="$(api "$jar" -F "file=@${tmpdir}/duplicate.pdf;type=application/pdf" http://localhost:8000/api/documents)"
echo "$first_upload" | jq -e '.document.display_name == "duplicate.pdf" and .document.readiness == "processing"' >/dev/null
first_id="$(echo "$first_upload" | jq -r '.document.id')"

make_pdf "/tmp/duplicate.pdf" "Duplicate Name Again" "Same filename creates a separate Managed Document."
docker cp "$(compose ps -q clickhouse):/tmp/duplicate.pdf" "$tmpdir/duplicate.pdf"
second_upload="$(api "$jar" -F "file=@${tmpdir}/duplicate.pdf;type=application/pdf" http://localhost:8000/api/documents)"
echo "$second_upload" | jq -e '.document.display_name == "duplicate.pdf" and .document.readiness == "processing"' >/dev/null
second_id="$(echo "$second_upload" | jq -r '.document.id')"

if [[ "$first_id" == "$second_id" ]]; then
  echo "same filename upload reused document_id unexpectedly" >&2
  exit 1
fi

doc_count="$(mysql_json "SELECT COUNT(*) FROM managed_documents WHERE original_filename='duplicate.pdf'")"
if [[ "$doc_count" != "2" ]]; then
  echo "expected two Managed Documents for duplicate filename, got $doc_count" >&2
  exit 1
fi

mysql_json "SELECT JSON_ARRAYAGG(JSON_OBJECT('id', id, 'user_id', user_id, 'object_key', latest_object_key, 'etag', latest_etag, 'filename', original_filename, 'size', size_bytes, 'content_type', content_type, 'readiness', readiness)) FROM managed_documents ORDER BY created_at" > "$tmpdir/docs.json"
python3 - "$tmpdir/docs.json" <<'PY'
import json
import sys

docs = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(docs) == 2, docs
for doc in docs:
    expected_prefix = f"users/{doc['user_id']}/documents/{doc['id']}/duplicate.pdf"
    assert doc["object_key"] == expected_prefix, doc
    assert doc["etag"], doc
    assert doc["filename"] == "duplicate.pdf", doc
    assert doc["size"] > 0, doc
    assert doc["content_type"] == "application/pdf", doc
    assert doc["readiness"] in {"processing", "ready"}, doc
PY

first_object_key="$(mysql_json "SELECT latest_object_key FROM managed_documents WHERE id='${first_id}'")"
compose exec -T backend python - "$first_object_key" <<'PY' >/dev/null
import os
import sys
from minio import Minio

client = Minio(
    os.environ["MINIO_ENDPOINT"],
    access_key=os.environ["MINIO_ACCESS_KEY"],
    secret_key=os.environ["MINIO_SECRET_KEY"],
    secure=os.environ.get("MINIO_SECURE", "false").lower() == "true",
)
client.stat_object(os.environ["MINIO_BUCKET"], sys.argv[1])
PY

txt="$tmpdir/not-supported.txt"
printf 'plain text' > "$txt"
unsupported_status="$(http_status "$jar" -F "file=@${txt};type=text/plain" http://localhost:8000/api/documents)"
assert_status "415" "$unsupported_status" "unsupported upload"

large="$tmpdir/large.pdf"
python3 - "$large" <<'PY'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"%PDF-1.4\n")
    f.write(b"0" * (26 * 1024 * 1024))
PY
large_status="$(http_status "$jar" -F "file=@${large};type=application/pdf" http://localhost:8000/api/documents)"
assert_status "413" "$large_status" "large upload"

api "$jar" "http://localhost:8000/api/documents?limit=1&offset=0" | jq -e '(.items | length) == 1 and .page.total == 2 and .page.limit == 1 and .page.offset == 0' >/dev/null
api "$jar" "http://localhost:8000/api/documents?q=duplicate&readiness=all&limit=25&offset=0" | jq -e '(.items | length) == 2' >/dev/null

for _ in $(seq 1 40); do
  runs="$(compose exec -T clickhouse clickhouse-client --password clickhouse --database document_pipeline --query "SELECT count() FROM ingestion_runs" | tr -d '[:space:]')"
  if (( runs > 0 )); then
    echo "Document upload smoke test passed."
    exit 0
  fi
  sleep 1
done

echo "timed out waiting for ClickHouse refresh run" >&2
exit 1
