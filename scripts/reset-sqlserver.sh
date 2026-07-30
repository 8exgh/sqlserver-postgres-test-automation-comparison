#!/usr/bin/env bash
#
# Drops the application database and re-applies everything from scratch.
# Use this between test suites when you want a guaranteed-clean fixture.
#
#   scripts/reset-sqlserver.sh              # drop DB, re-apply
#   scripts/reset-sqlserver.sh --hard       # also destroy the container volume
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env
PW="${MSSQL_SA_PASSWORD:-Str0ng!Passw0rd}"
DB="CdnTaxPractice"

HARD=0
if [[ "${1:-}" == "--hard" ]]; then
  HARD=1
  shift        # remaining args are forwarded to apply-sqlserver.sh
fi

if (( HARD )); then
  printf '\033[1;34m==>\033[0m Destroying container and volume\n'
  docker compose down -v
else
  printf '\033[1;34m==>\033[0m Dropping database %s\n' "$DB"
  # SINGLE_USER + ROLLBACK IMMEDIATE so an open session can't block the drop.
  docker compose exec -T sqlserver /opt/mssql-tools18/bin/sqlcmd \
    -C -b -S localhost -U sa -P "$PW" -d master -Q "
      IF DB_ID('$DB') IS NOT NULL
      BEGIN
          ALTER DATABASE [$DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
          DROP DATABASE [$DB];
      END" || true
fi

exec "$REPO_ROOT/scripts/apply-sqlserver.sh" "$@"
