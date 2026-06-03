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
  curl -sS -o /tmp/clickvector-replace-response.json -w "%{http_code}" -c "$jar" -b "$jar" "$@"
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
    cat /tmp/clickvector-replace-response.json >&2 || true
    exit 1
  fi
}

metadata_snapshot() {
  local document_id="$1"
  mysql_scalar "SELECT CONCAT(latest_object_key, '|', latest_etag, '|', original_filename, '|', size_bytes, '|', content_type, '|', display_name, '|', display_name_overridden) FROM managed_documents WHERE id='${document_id}'"
}

compose down -v --remove-orphans
compose up -d --build --wait mysql minio clickhouse backend frontend

jar="$(mktemp)"
bob_jar="$(mktemp)"
tmpdir="/tmp/clickvector-replace-smoke"
mkdir -p "$tmpdir"

api "$jar" -H 'Content-Type: application/json' \
  -d '{"email":"replace@example.com","password":"password123","display_name":"Replace"}' \
  http://localhost:8000/api/auth/register | jq -e '.user.email == "replace@example.com"' >/dev/null
api "$bob_jar" -H 'Content-Type: application/json' \
  -d '{"email":"replace-bob@example.com","password":"password123","display_name":"Bob"}' \
  http://localhost:8000/api/auth/register | jq -e '.user.email == "replace-bob@example.com"' >/dev/null

make_pdf "/tmp/original.pdf" "Original" "Original version for replace behavior."
docker cp "$(compose ps -q clickhouse):/tmp/original.pdf" "$tmpdir/original.pdf"
upload="$(api "$jar" -F "file=@${tmpdir}/original.pdf;type=application/pdf" http://localhost:8000/api/documents)"
follow_id="$(echo "$upload" | jq -r '.document.id')"
wait_ready "$jar" "$follow_id"
before_invalid="$(metadata_snapshot "$follow_id")"

txt="$tmpdir/not-supported.txt"
printf 'plain text' > "$txt"
unsupported_status="$(http_status "$jar" -F "file=@${txt};type=text/plain" "http://localhost:8000/api/documents/${follow_id}/replace")"
assert_status "415" "$unsupported_status" "unsupported replace"
after_unsupported="$(metadata_snapshot "$follow_id")"
if [[ "$before_invalid" != "$after_unsupported" ]]; then
  echo "unsupported replace mutated latest metadata" >&2
  exit 1
fi

large="$tmpdir/large.pdf"
python3 - "$large" <<'PY'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"%PDF-1.4\n")
    f.write(b"0" * (26 * 1024 * 1024))
PY
large_status="$(http_status "$jar" -F "file=@${large};type=application/pdf" "http://localhost:8000/api/documents/${follow_id}/replace")"
assert_status "413" "$large_status" "large replace"
after_large="$(metadata_snapshot "$follow_id")"
if [[ "$before_invalid" != "$after_large" ]]; then
  echo "large replace mutated latest metadata" >&2
  exit 1
fi

bob_status="$(http_status "$bob_jar" -F "file=@${tmpdir}/original.pdf;type=application/pdf" "http://localhost:8000/api/documents/${follow_id}/replace")"
assert_status "404" "$bob_status" "other user replace"

make_pdf "/tmp/new-name.pdf" "New Name" "Display name should follow filename when not overridden."
docker cp "$(compose ps -q clickhouse):/tmp/new-name.pdf" "$tmpdir/new-name.pdf"
replace_follow="$(api "$jar" -F "file=@${tmpdir}/new-name.pdf;type=application/pdf" "http://localhost:8000/api/documents/${follow_id}/replace")"
echo "$replace_follow" | jq -e --arg id "$follow_id" '.document.id == $id and .document.display_name == "new-name.pdf" and .document.readiness == "processing"' >/dev/null
wait_ready "$jar" "$follow_id"
follow_versions="$(ch_scalar "SELECT countDistinct(etag) FROM document_ingestions FINAL WHERE document_id='${follow_id}' AND status='completed'")"
if [[ "$follow_versions" != "2" ]]; then
  echo "replace did not create a second completed Document Version for same Managed Document" >&2
  exit 1
fi

make_pdf "/tmp/manual.pdf" "Manual" "Manual display name should survive replace."
docker cp "$(compose ps -q clickhouse):/tmp/manual.pdf" "$tmpdir/manual.pdf"
manual_upload="$(api "$jar" -F "file=@${tmpdir}/manual.pdf;type=application/pdf" http://localhost:8000/api/documents)"
manual_id="$(echo "$manual_upload" | jq -r '.document.id')"
wait_ready "$jar" "$manual_id"
api "$jar" -X PATCH -H 'Content-Type: application/json' \
  -d '{"display_name":"Manual Display"}' \
  "http://localhost:8000/api/documents/${manual_id}" | jq -e '.document.display_name == "Manual Display"' >/dev/null

make_pdf "/tmp/manual-replaced.pdf" "Manual Replaced" "Manual display should stay."
docker cp "$(compose ps -q clickhouse):/tmp/manual-replaced.pdf" "$tmpdir/manual-replaced.pdf"
manual_replace="$(api "$jar" -F "file=@${tmpdir}/manual-replaced.pdf;type=application/pdf" "http://localhost:8000/api/documents/${manual_id}/replace")"
echo "$manual_replace" | jq -e --arg id "$manual_id" '.document.id == $id and .document.display_name == "Manual Display" and .document.readiness == "processing"' >/dev/null
wait_ready "$jar" "$manual_id"
manual_versions="$(ch_scalar "SELECT countDistinct(etag) FROM document_ingestions FINAL WHERE document_id='${manual_id}' AND status='completed'")"
if [[ "$manual_versions" != "2" ]]; then
  echo "manual replace did not create a second completed Document Version" >&2
  exit 1
fi

echo "Document replace smoke test passed."
