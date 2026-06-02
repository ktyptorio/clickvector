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
  curl -sS -o /tmp/clickvector-auth-response.json -w "%{http_code}" -c "$jar" -b "$jar" "$@"
}

mysql_scalar() {
  compose exec -T mysql mysql -N -B -uclickvector -pclickvector clickvector -e "$1" 2>/dev/null
}

cookie_hash() {
  local jar="$1"
  python3 - "$jar" <<'PY'
import hashlib
import sys

jar = sys.argv[1]
for line in open(jar, encoding="utf-8"):
    if line.startswith("#HttpOnly_"):
        line = line.removeprefix("#HttpOnly_")
    elif line.startswith("#") or not line.strip():
        continue
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 7 and parts[5] == "cv_session":
        print(hashlib.sha256(parts[6].encode()).hexdigest())
        raise SystemExit(0)
raise SystemExit("cv_session cookie not found")
PY
}

assert_status() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "$label expected HTTP $expected, got $actual" >&2
    cat /tmp/clickvector-auth-response.json >&2 || true
    exit 1
  fi
}

compose down -v --remove-orphans
compose up -d --build --wait mysql minio clickhouse backend frontend

jar="$(mktemp)"
expired_jar="$(mktemp)"

api "$jar" -H 'Content-Type: application/json' \
  -d '{"email":"ALICE@EXAMPLE.COM","password":"password123","display_name":"Alice"}' \
  http://localhost:8000/api/auth/register | jq -e '.user.email == "alice@example.com"' >/dev/null

stored_hash="$(mysql_scalar "SELECT password_hash FROM users WHERE email='alice@example.com'")"
if [[ "$stored_hash" != \$argon2id\$* ]]; then
  echo "expected Argon2id password hash, got: $stored_hash" >&2
  exit 1
fi

ttl_seconds="$(mysql_scalar "SELECT TIMESTAMPDIFF(SECOND, created_at, expires_at) FROM sessions ORDER BY created_at DESC LIMIT 1")"
if (( ttl_seconds < 3590 || ttl_seconds > 3610 )); then
  echo "expected session TTL close to 3600 seconds, got $ttl_seconds" >&2
  exit 1
fi

duplicate_status="$(http_status "$jar" -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com","password":"password123"}' \
  http://localhost:8000/api/auth/register)"
assert_status "409" "$duplicate_status" "duplicate registration"

invalid_status="$(http_status "$jar" -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com","password":"wrong-password"}' \
  http://localhost:8000/api/auth/login)"
assert_status "401" "$invalid_status" "invalid login"

api "$jar" http://localhost:8000/api/auth/me | jq -e '.user.email == "alice@example.com"' >/dev/null

api "$expired_jar" -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com","password":"password123"}' \
  http://localhost:8000/api/auth/login | jq -e '.user.email == "alice@example.com"' >/dev/null
expired_hash="$(cookie_hash "$expired_jar")"
mysql_scalar "UPDATE sessions SET expires_at = DATE_SUB(UTC_TIMESTAMP(6), INTERVAL 1 SECOND) WHERE token_hash='${expired_hash}'" >/dev/null
expired_status="$(http_status "$expired_jar" http://localhost:8000/api/auth/me)"
assert_status "401" "$expired_status" "expired session"

api "$jar" -X POST http://localhost:8000/api/auth/logout >/dev/null
logout_status="$(http_status "$jar" http://localhost:8000/api/auth/me)"
assert_status "401" "$logout_status" "logout session"

revoked_count="$(mysql_scalar "SELECT COUNT(*) FROM sessions WHERE revoked_at IS NOT NULL")"
if (( revoked_count < 1 )); then
  echo "expected at least one revoked session after logout" >&2
  exit 1
fi

echo "Auth smoke test passed."
