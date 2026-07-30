#!/usr/bin/env bash
#
# Brings up the SQL Server container (if needed), waits for it to accept
# connections, then applies every numbered migration in db/sqlserver in order.
#
# sqlcmd is executed *inside* the container, so nothing needs to be installed
# on the host. -b makes sqlcmd exit non-zero on a T-SQL error so a broken
# migration fails this script instead of silently continuing.
#
# Usage:
#   scripts/apply-sqlserver.sh              # apply everything
#   scripts/apply-sqlserver.sh --skip-seed  # schema + programmability only
#   scripts/apply-sqlserver.sh --no-verify  # skip 099_verify.sql
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env
PW="${MSSQL_SA_PASSWORD:-Str0ng!Passw0rd}"
SERVICE="sqlserver"
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
DB="CdnTaxPractice"

SKIP_SEED=0
RUN_VERIFY=1
for arg in "$@"; do
  case "$arg" in
    --skip-seed) SKIP_SEED=1 ;;
    --no-verify) RUN_VERIFY=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }

compose() { docker compose "$@"; }

log "Starting $SERVICE"
compose up -d "$SERVICE"

log "Waiting for SQL Server to accept connections (emulated boot can take ~2 min)"
deadline=$(( SECONDS + 300 ))
until compose exec -T "$SERVICE" "$SQLCMD" -C -S localhost -U sa -P "$PW" -Q "SELECT 1" -b -t 5 >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    err "SQL Server did not become ready within 300s. Recent container logs:"
    compose logs --tail 40 "$SERVICE" >&2
    exit 1
  fi
  sleep 5
done
log "SQL Server is up"

# Runs one script. Files 002+ target the application database; 001 creates it
# and therefore must run against master.
run_file() {
  local file="$1" db="$2"
  local base
  base="$(basename "$file")"
  printf '    %-38s' "$base"
  local out
  if out=$(compose exec -T "$SERVICE" "$SQLCMD" \
        -C -b -S localhost -U sa -P "$PW" -d "$db" \
        -i "/db/sqlserver/$base" -I 2>&1); then
    printf 'ok\n'
    # Surface PRINT output from the verify script even on success.
    if [[ "$base" == 099_* && -n "$out" ]]; then
      printf '%s\n' "$out" | sed 's/^/        /'
    fi
  else
    printf 'FAILED\n'
    printf '%s\n' "$out" | sed 's/^/        /' >&2
    return 1
  fi
}

log "Applying schema"
run_file 001_database_and_schemas.sql master

for f in db/sqlserver/0[0-1]*.sql; do
  [[ "$(basename "$f")" == 001_* ]] && continue
  run_file "$f" "$DB"
done

if (( SKIP_SEED )); then
  log "Skipping seed data (--skip-seed)"
else
  log "Seeding data"
  for f in db/sqlserver/02*.sql; do
    run_file "$f" "$DB"
  done
fi

if (( RUN_VERIFY )); then
  log "Verifying"
  run_file db/sqlserver/099_verify.sql "$DB"
fi

log "Done. Connect with: localhost,11433  user: sa  database: $DB"
