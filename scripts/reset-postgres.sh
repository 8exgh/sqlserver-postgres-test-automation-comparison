#!/usr/bin/env bash
#
# Drops every ported schema and re-applies db/postgres from scratch.
#
#   scripts/reset-postgres.sh          # drop schemas, re-apply, verify
#   scripts/reset-postgres.sh --hard   # also destroy the container volume
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env
PGUSER_="${PGUSER:-postgres}"
PGDATABASE_="${PGDATABASE:-cdntaxpractice}"

HARD=0
if [[ "${1:-}" == "--hard" ]]; then HARD=1; shift; fi

if (( HARD )); then
  printf '\033[1;34m==>\033[0m Destroying the postgres container and volume\n'
  docker compose rm -sf postgres >/dev/null 2>&1 || true
  docker volume rm -f "$(basename "$REPO_ROOT")_pg-data" >/dev/null 2>&1 || true
  docker compose up -d postgres >/dev/null
  deadline=$(( SECONDS + 120 ))
  until docker compose exec -T postgres pg_isready -U "$PGUSER_" -d "$PGDATABASE_" >/dev/null 2>&1; do
    (( SECONDS >= deadline )) && { echo "postgres not ready" >&2; exit 1; }
    sleep 2
  done
else
  printf '\033[1;34m==>\033[0m Dropping ported schemas\n'
  # Also drops the schemas AWS SCT creates, so a reset clears both the hand
  # port and anything left behind by a --apply conversion run.
  # client_min_messages=warning suppresses the hundreds of "drop cascades to"
  # notices the extension-pack schema produces.
  docker compose exec -T postgres psql -U "$PGUSER_" -d "$PGDATABASE_" \
    --quiet --no-psqlrc -c "SET client_min_messages = warning;" -c "
      DROP SCHEMA IF EXISTS ref, client, tax, acct, payroll, audit, util CASCADE;
      DROP SCHEMA IF EXISTS ${PGDATABASE_}_ref, ${PGDATABASE_}_client, ${PGDATABASE_}_tax,
                            ${PGDATABASE_}_acct, ${PGDATABASE_}_payroll, ${PGDATABASE_}_audit,
                            ${PGDATABASE_}_util, ${PGDATABASE_}_dbo CASCADE;
      DROP SCHEMA IF EXISTS aws_sqlserver_ext CASCADE;" >/dev/null
fi

exec "$REPO_ROOT/scripts/apply-postgres.sh" "$@"
