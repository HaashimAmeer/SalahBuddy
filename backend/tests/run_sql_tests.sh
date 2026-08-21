#!/usr/bin/env bash
#
# Applies the shim + every migration to a throwaway database, then runs every
# assertion file in tests/sql/. Exits non-zero on the first failing file's
# expectations so CI turns red.
#
# Connection: set PGURI for a full conninfo string, or the usual libpq env vars
#   PGHOST / PGPORT / PGUSER / PGPASSWORD / PGDATABASE.
# Defaults to the sandbox's socket-mode Postgres (-h /tmp -p 5433 -U postgres).
# GitHub Actions (services: postgres:16) just needs:
#   PGURI=postgresql://postgres@localhost:5432/postgres PGPASSWORD=postgres ./run_sql_tests.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "$TESTS_DIR/.." && pwd)"
MIGRATIONS_DIR="$BACKEND_DIR/supabase/migrations"
SHIM_DIR="$TESTS_DIR/shim"
SQL_DIR="$TESTS_DIR/sql"

# --- connection ------------------------------------------------------------
if [[ -z "${PGURI:-}" ]]; then
  host="${PGHOST:-/tmp}"
  port="${PGPORT:-5433}"
  user="${PGUSER:-postgres}"
  db="${PGDATABASE:-postgres}"
  if [[ "$host" == /* ]]; then
    # Unix socket: the directory goes in the query string, not the authority.
    PGURI="postgresql://${user}@/${db}?host=${host}&port=${port}"
  else
    PGURI="postgresql://${user}@${host}:${port}/${db}"
  fi
fi
# Passwords stay in PGPASSWORD (libpq reads it) so nothing secret is ever built
# into a URI that might get echoed into a CI log.

# Swap the database name in a conninfo URI, preserving the query string.
uri_with_db() {
  local uri="$1" db="$2" base query scheme rest authority
  base="${uri%%\?*}"
  query=""
  [[ "$uri" == *\?* ]] && query="?${uri#*\?}"
  scheme="${base%%://*}"
  rest="${base#*://}"
  authority="${rest%%/*}"
  printf '%s://%s/%s%s' "$scheme" "$authority" "$db" "$query"
}

SCRATCH_DB="${SCRATCH_DB:-salahbuddy_test_$$}"
ADMIN_URI="$PGURI"
SCRATCH_URI="$(uri_with_db "$PGURI" "$SCRATCH_DB")"

PSQL_BASE=(psql --no-psqlrc --quiet --no-password -v ON_ERROR_STOP=1)
# "policy … does not exist, skipping" from the idempotent drops is noise; real
# problems are WARNING or worse. Override with PGOPTIONS to see them.
export PGOPTIONS="${PGOPTIONS:--c client_min_messages=warning}"

cleanup() {
  "${PSQL_BASE[@]}" "$ADMIN_URI" -c "drop database if exists \"$SCRATCH_DB\" with (force);" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> scratch database: $SCRATCH_DB"
"${PSQL_BASE[@]}" "$ADMIN_URI" -c "drop database if exists \"$SCRATCH_DB\" with (force);" >/dev/null
"${PSQL_BASE[@]}" "$ADMIN_URI" -c "create database \"$SCRATCH_DB\";" >/dev/null

echo "==> shim"
for f in "$SHIM_DIR"/*.sql; do
  [[ -e "$f" ]] || continue
  "${PSQL_BASE[@]}" "$SCRATCH_URI" --single-transaction -f "$f" >/dev/null
  echo "    applied $(basename "$f")"
done

echo "==> migrations"
shopt -s nullglob
migrations=("$MIGRATIONS_DIR"/*.sql)
shopt -u nullglob
if (( ${#migrations[@]} == 0 )); then
  echo "no migrations found in $MIGRATIONS_DIR" >&2
  exit 1
fi
# Filenames are <timestamp>_name.sql, so lexical order is apply order — the same
# ordering `supabase db push` uses.
IFS=$'\n' migrations=($(printf '%s\n' "${migrations[@]}" | sort)); unset IFS
for f in "${migrations[@]}"; do
  "${PSQL_BASE[@]}" "$SCRATCH_URI" --single-transaction -f "$f" >/dev/null
  echo "    applied $(basename "$f")"
done

echo "==> tests"
pass=0
fail=0
failed_files=()
shopt -s nullglob
tests=("$SQL_DIR"/*.sql)
shopt -u nullglob
if (( ${#tests[@]} == 0 )); then
  echo "no test files found in $SQL_DIR" >&2
  exit 1
fi
IFS=$'\n' tests=($(printf '%s\n' "${tests[@]}" | sort)); unset IFS

for f in "${tests[@]}"; do
  name="$(basename "$f")"
  if output="$("${PSQL_BASE[@]}" "$SCRATCH_URI" -f "$f" 2>&1)"; then
    pass=$((pass + 1))
    printf '    PASS  %s\n' "$name"
  else
    fail=$((fail + 1))
    failed_files+=("$name")
    printf '    FAIL  %s\n' "$name"
    printf '%s\n' "$output" | sed 's/^/          /'
  fi
done

echo
if (( fail > 0 )); then
  echo "FAILED: ${failed_files[*]}"
fi
echo "${pass} passed, ${fail} failed"
(( fail == 0 ))
