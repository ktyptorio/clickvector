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
  curl -sS -o /tmp/clickvector-actions-response.bin -w "%{http_code}" -c "$jar" -b "$jar" "$@"
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

wait_ready() {
  local jar="$1"
  local document_id="$2"
  for _ in $(seq 1 80); do
    readiness="$(api "$jar" "http://localhost:8000/api/documents/${document_id}" | jq -r '.document.readiness')"
    if [[ "$readiness" == "ready" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for ready document ${document_id}; actual=${readiness}" >&2
  return 1
}

assert_status() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "$label expected HTTP $expected, got $actual" >&2
    cat /tmp/clickvector-actions-response.bin >&2 || true
    exit 1
  fi
}

assert_minio_object_exists() {
  local object_key="$1"
  compose exec -T backend python - "$object_key" <<'PY' >/dev/null
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
}

compose down -v --remove-orphans
compose up -d --build --wait mysql minio clickhouse backend frontend

alice_jar="$(mktemp)"
bob_jar="$(mktemp)"
tmpdir="/tmp/clickvector-actions-smoke"
mkdir -p "$tmpdir"

api "$alice_jar" -H 'Content-Type: application/json' \
  -d '{"email":"alice-actions@example.com","password":"password123","display_name":"Alice"}' \
  http://localhost:8000/api/auth/register | jq -e '.user.email == "alice-actions@example.com"' >/dev/null
api "$bob_jar" -H 'Content-Type: application/json' \
  -d '{"email":"bob-actions@example.com","password":"password123","display_name":"Bob"}' \
  http://localhost:8000/api/auth/register | jq -e '.user.email == "bob-actions@example.com"' >/dev/null

make_pdf "/tmp/actions.pdf" "Actions" "This document is used to verify rename archive and download behavior."
docker cp "$(compose ps -q clickhouse):/tmp/actions.pdf" "$tmpdir/actions.pdf"
upload="$(api "$alice_jar" -F "file=@${tmpdir}/actions.pdf;type=application/pdf" http://localhost:8000/api/documents)"
document_id="$(echo "$upload" | jq -r '.document.id')"
wait_ready "$alice_jar" "$document_id"

object_key="$(mysql_scalar "SELECT latest_object_key FROM managed_documents WHERE id='${document_id}'")"
assert_minio_object_exists "$object_key"
chunks_before="$(ch_scalar "SELECT count() FROM document_chunks WHERE document_id='${document_id}'")"
if [[ "$chunks_before" == "0" ]]; then
  echo "expected chunks before archive" >&2
  exit 1
fi

api "$alice_jar" -X PATCH -H 'Content-Type: application/json' \
  -d '{"display_name":"Renamed Actions"}' \
  "http://localhost:8000/api/documents/${document_id}" | jq -e '.document.display_name == "Renamed Actions"' >/dev/null
override_flag="$(mysql_scalar "SELECT display_name_overridden FROM managed_documents WHERE id='${document_id}'")"
stored_name="$(mysql_scalar "SELECT display_name FROM managed_documents WHERE id='${document_id}'")"
if [[ "$override_flag" != "1" || "$stored_name" != "Renamed Actions" ]]; then
  echo "rename did not persist display_name override" >&2
  exit 1
fi

bob_rename_status="$(http_status "$bob_jar" -X PATCH -H 'Content-Type: application/json' -d '{"display_name":"Nope"}' "http://localhost:8000/api/documents/${document_id}")"
assert_status "404" "$bob_rename_status" "other user rename"
bob_download_status="$(http_status "$bob_jar" "http://localhost:8000/api/documents/${document_id}/download")"
assert_status "404" "$bob_download_status" "other user download"
bob_archive_status="$(http_status "$bob_jar" -X DELETE "http://localhost:8000/api/documents/${document_id}")"
assert_status "404" "$bob_archive_status" "other user archive"

download_path="$tmpdir/downloaded.pdf"
api "$alice_jar" "http://localhost:8000/api/documents/${document_id}/download" > "$download_path"
python3 - "$download_path" <<'PY'
import sys
with open(sys.argv[1], "rb") as f:
    assert f.read(5) == b"%PDF-", "download did not stream a PDF"
PY

api "$alice_jar" -X DELETE "http://localhost:8000/api/documents/${document_id}" >/dev/null
readiness="$(mysql_scalar "SELECT readiness FROM managed_documents WHERE id='${document_id}'")"
archived_count="$(mysql_scalar "SELECT COUNT(*) FROM managed_documents WHERE id='${document_id}' AND archived_at IS NOT NULL")"
if [[ "$readiness" != "archived" || "$archived_count" != "1" ]]; then
  echo "archive did not soft-delete the Managed Document" >&2
  exit 1
fi

api "$alice_jar" "http://localhost:8000/api/documents?limit=50&offset=0" | jq -e --arg id "$document_id" 'all(.items[]; .id != $id)' >/dev/null
api "$alice_jar" -H 'Content-Type: application/json' \
  -d '{"query":"rename archive download","top_k":10}' \
  http://localhost:8000/api/query | jq -e '.results | length == 0' >/dev/null

assert_minio_object_exists "$object_key"
chunks_after="$(ch_scalar "SELECT count() FROM document_chunks WHERE document_id='${document_id}'")"
if [[ "$chunks_after" != "$chunks_before" ]]; then
  echo "archive changed ClickHouse chunks unexpectedly; before=${chunks_before} after=${chunks_after}" >&2
  exit 1
fi

echo "Document actions smoke test passed."
