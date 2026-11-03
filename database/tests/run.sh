#!/usr/bin/env bash
# Builds a throwaway database from database/sql + database/migrations and runs
# the security tests. NEVER point this at Supabase: it drops the target DB.
#   PGHOST=/tmp PGPORT=5432 PGUSER=postgres database/tests/run.sh
set -euo pipefail
DB="${TEST_DB:-serveflow_security_test}"
HERE="$(cd "$(dirname "$0")" && pwd)"
P=(psql -v ON_ERROR_STOP=1 -q)
"${P[@]}" -d postgres -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB" >/dev/null
"${P[@]}" -d "$DB" -f "$HERE/supabase_auth_stub.sql"
for f in "$HERE"/../sql/0*.sql "$HERE"/../migrations/*security_hardening.sql; do
  "${P[@]}" -d "$DB" -f "$f" 2>&1 | grep -v NOTICE || true
done
"${P[@]}" -d "$DB" -f "$HERE/security_tests.sql" 2>&1 | grep -E '\|' | tail -n +1
"${P[@]}" -d postgres -c "DROP DATABASE $DB"
