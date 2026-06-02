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
y = 690
for wordline in [body[i:i+96] for i in range(0, len(body), 96)]:
    pdf.drawString(72, y, wordline)
    y -= 16
pdf.save()
PY
}

upload_doc() {
  local jar="$1"
  local local_path="$2"
  api "$jar" -F "file=@${local_path};type=application/pdf" http://localhost:8000/api/documents
}

wait_ready_count() {
  local jar="$1"
  local expected="$2"
  local ready="0"
  for _ in $(seq 1 80); do
    ready="$(api "$jar" http://localhost:8000/api/documents | jq '[.items[] | select(.readiness=="ready")] | length')"
    if [[ "$ready" == "$expected" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for $expected ready documents; actual=$ready" >&2
  api "$jar" http://localhost:8000/api/documents | jq .
  return 1
}

compose down -v --remove-orphans
compose up -d --build --wait

jar1="$(mktemp)"
jar2="$(mktemp)"
tmpdir="/tmp/clickvector-smoke"
mkdir -p "$tmpdir"

api "$jar1" -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com","password":"password123","display_name":"Alice"}' \
  http://localhost:8000/api/auth/register | jq .

make_pdf "/tmp/initial.pdf" "Policy Handbook" "Credential rotation, audit logging, incident response, and document retention are managed in this policy handbook."
docker cp "$(compose ps -q clickhouse):/tmp/initial.pdf" "$tmpdir/initial.pdf"
upload_doc "$jar1" "$tmpdir/initial.pdf" | jq .
wait_ready_count "$jar1" 1

make_pdf "/tmp/security.pdf" "Security Guide" "The security guide explains credential rotation, audit logging, encryption expectations, and operational ownership."
make_pdf "/tmp/product.pdf" "Product Notes" "Product notes summarize retrieval behavior, latest completed document versions, and cosine distance ranking."
docker cp "$(compose ps -q clickhouse):/tmp/security.pdf" "$tmpdir/security.pdf"
docker cp "$(compose ps -q clickhouse):/tmp/product.pdf" "$tmpdir/product.pdf"
upload_doc "$jar1" "$tmpdir/security.pdf" | jq .
upload_doc "$jar1" "$tmpdir/product.pdf" | jq .
wait_ready_count "$jar1" 3

first_id="$(api "$jar1" http://localhost:8000/api/documents | jq -r '.items[] | select(.display_name=="initial.pdf") | .id' | head -n1)"
make_pdf "/tmp/initial-v2.pdf" "Policy Handbook Updated" "The updated handbook adds incident response and keeps retrieval focused on latest completed document versions."
docker cp "$(compose ps -q clickhouse):/tmp/initial-v2.pdf" "$tmpdir/initial-v2.pdf"
api "$jar1" -F "file=@${tmpdir}/initial-v2.pdf;type=application/pdf" "http://localhost:8000/api/documents/${first_id}/replace" | jq .
wait_ready_count "$jar1" 3

archive_id="$(api "$jar1" http://localhost:8000/api/documents | jq -r '.items[] | select(.display_name=="product.pdf") | .id' | head -n1)"
api "$jar1" -X DELETE "http://localhost:8000/api/documents/${archive_id}"

query_result="$(api "$jar1" -H 'Content-Type: application/json' -d '{"query":"credential rotation audit logging","top_k":10}' http://localhost:8000/api/query)"
echo "$query_result" | jq .
echo "$query_result" | jq -e '.results | length >= 1' >/dev/null

api "$jar2" -H 'Content-Type: application/json' \
  -d '{"email":"bob@example.com","password":"password123","display_name":"Bob"}' \
  http://localhost:8000/api/auth/register | jq .
api "$jar2" http://localhost:8000/api/documents | jq -e '.items | length == 0' >/dev/null

echo "document_ingestions"
compose exec -T clickhouse clickhouse-client --password clickhouse --database document_pipeline --query "SELECT user_id, document_id, object_key, status, chunk_count FROM document_ingestions FINAL ORDER BY updated_at FORMAT PrettyCompact"
echo "document_chunks"
compose exec -T clickhouse clickhouse-client --password clickhouse --database document_pipeline --query "SELECT user_id, document_id, count() AS chunks FROM document_chunks GROUP BY user_id, document_id FORMAT PrettyCompact"
echo "managed_documents"
compose exec -T mysql mysql -uclickvector -pclickvector clickvector -e "SELECT users.email, managed_documents.display_name, managed_documents.readiness, managed_documents.chunk_count, managed_documents.archived_at IS NOT NULL AS archived FROM managed_documents JOIN users ON users.id=managed_documents.user_id ORDER BY managed_documents.created_at"
