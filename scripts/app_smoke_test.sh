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

make_docx() {
  local output="$1"
  local title="$2"
  local body="$3"
  compose exec -T clickhouse /opt/document-pipeline/.venv/bin/python - "$output" "$title" "$body" <<'PY'
import sys
from docx import Document
path, title, body = sys.argv[1], sys.argv[2], sys.argv[3]
doc = Document()
doc.add_heading(title, level=1)
doc.add_paragraph(body)
doc.save(path)
PY
}

upload_doc() {
  local jar="$1"
  local local_path="$2"
  local content_type="application/pdf"
  if [[ "$local_path" == *.docx ]]; then
    content_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  fi
  api "$jar" -F "file=@${local_path};type=${content_type}" http://localhost:8000/api/documents
}

replace_doc() {
  local jar="$1"
  local document_id="$2"
  local local_path="$3"
  local content_type="application/pdf"
  if [[ "$local_path" == *.docx ]]; then
    content_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  fi
  api "$jar" -F "file=@${local_path};type=${content_type}" "http://localhost:8000/api/documents/${document_id}/replace"
}

mysql_scalar() {
  local sql="$1"
  compose exec -T mysql mysql -N -B -uclickvector -pclickvector clickvector -e "$sql"
}

ch_scalar() {
  local sql="$1"
  compose exec -T clickhouse clickhouse-client --password clickhouse --database document_pipeline --query "$sql"
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
make_docx "/tmp/operations.docx" "Operations Memo" "Operations memo describes audit evidence, access review, and support handoff steps for managed documents."
docker cp "$(compose ps -q clickhouse):/tmp/security.pdf" "$tmpdir/security.pdf"
docker cp "$(compose ps -q clickhouse):/tmp/product.pdf" "$tmpdir/product.pdf"
docker cp "$(compose ps -q clickhouse):/tmp/operations.docx" "$tmpdir/operations.docx"
upload_doc "$jar1" "$tmpdir/security.pdf" | jq .
upload_doc "$jar1" "$tmpdir/product.pdf" | jq .
upload_doc "$jar1" "$tmpdir/operations.docx" | jq .
wait_ready_count "$jar1" 4

first_id="$(api "$jar1" http://localhost:8000/api/documents | jq -r '.items[] | select(.display_name=="initial.pdf") | .id' | head -n1)"
make_pdf "/tmp/initial-v2.pdf" "Policy Handbook Updated" "The updated handbook adds incident response and keeps retrieval focused on latest completed document versions."
docker cp "$(compose ps -q clickhouse):/tmp/initial-v2.pdf" "$tmpdir/initial-v2.pdf"
replace_doc "$jar1" "$first_id" "$tmpdir/initial-v2.pdf" | jq .
wait_ready_count "$jar1" 4

version_count="$(ch_scalar "SELECT countDistinct(etag) FROM document_ingestions FINAL WHERE document_id='${first_id}' AND status='completed'")"
if [[ "$version_count" != "2" ]]; then
  echo "expected replace to create 2 completed versions for ${first_id}; actual=${version_count}" >&2
  exit 1
fi

archive_id="$(api "$jar1" http://localhost:8000/api/documents | jq -r '.items[] | select(.display_name=="product.pdf") | .id' | head -n1)"
archive_object_key="$(mysql_scalar "SELECT latest_object_key FROM managed_documents WHERE id='${archive_id}'")"
api "$jar1" -X DELETE "http://localhost:8000/api/documents/${archive_id}"
assert_minio_object_exists "$archive_object_key"
api "$jar1" http://localhost:8000/api/documents | jq -e '.items | all(.display_name != "product.pdf")' >/dev/null

query_result="$(api "$jar1" -H 'Content-Type: application/json' -d '{"query":"credential rotation audit logging","top_k":10}' http://localhost:8000/api/query)"
echo "$query_result" | jq .
echo "$query_result" | jq -e '.results | length >= 1' >/dev/null
echo "$query_result" | jq -e '.results | all(.document_display_name != "product.pdf")' >/dev/null

api "$jar2" -H 'Content-Type: application/json' \
  -d '{"email":"bob@example.com","password":"password123","display_name":"Bob"}' \
  http://localhost:8000/api/auth/register | jq .
api "$jar2" http://localhost:8000/api/documents | jq -e '.items | length == 0' >/dev/null

make_pdf "/tmp/bob.pdf" "Bob Private Plan" "Bob private plan covers user isolation, private document ownership, and separate query visibility."
docker cp "$(compose ps -q clickhouse):/tmp/bob.pdf" "$tmpdir/bob.pdf"
upload_doc "$jar2" "$tmpdir/bob.pdf" | jq .
wait_ready_count "$jar2" 1

alice_list_after_bob="$(api "$jar1" http://localhost:8000/api/documents)"
echo "$alice_list_after_bob" | jq -e '.items | all(.display_name != "bob.pdf")' >/dev/null

alice_isolation_query="$(api "$jar1" -H 'Content-Type: application/json' -d '{"query":"Bob private plan user isolation","top_k":10}' http://localhost:8000/api/query)"
echo "$alice_isolation_query" | jq -e '.results | all(.document_display_name != "bob.pdf")' >/dev/null

bob_query="$(api "$jar2" -H 'Content-Type: application/json' -d '{"query":"Bob private plan user isolation","top_k":10}' http://localhost:8000/api/query)"
echo "$bob_query" | jq .
echo "$bob_query" | jq -e '(.results | length >= 1) and all(.results[]; .document_display_name == "bob.pdf")' >/dev/null

echo "document_ingestions"
compose exec -T clickhouse clickhouse-client --password clickhouse --database document_pipeline --query "SELECT user_id, document_id, object_key, status, chunk_count FROM document_ingestions FINAL ORDER BY updated_at FORMAT PrettyCompact"
echo "document_chunks"
compose exec -T clickhouse clickhouse-client --password clickhouse --database document_pipeline --query "SELECT user_id, document_id, count() AS chunks FROM document_chunks GROUP BY user_id, document_id FORMAT PrettyCompact"
echo "managed_documents"
compose exec -T mysql mysql -uclickvector -pclickvector clickvector -e "SELECT users.email, managed_documents.display_name, managed_documents.readiness, managed_documents.chunk_count, managed_documents.archived_at IS NOT NULL AS archived FROM managed_documents JOIN users ON users.id=managed_documents.user_id ORDER BY managed_documents.created_at"
echo "query_summary"
echo "$query_result" | jq '{alice_result_count: (.results | length), alice_documents: [.results[].document_display_name] | unique}'
echo "$bob_query" | jq '{bob_result_count: (.results | length), bob_documents: [.results[].document_display_name] | unique}'
