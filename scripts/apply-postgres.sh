#!/usr/bin/env bash
#
# Applies db/postgres/*.sql to the PostgreSQL container, in order, stopping at
# the first error with the statement that caused it.
#
#   scripts/apply-postgres.sh              # apply everything, then verify
#   scripts/apply-postgres.sh --skip-seed  # schema + programmability only
#   scripts/apply-postgres.sh --no-verify  # skip the acceptance gate
#   scripts/apply-postgres.sh --only 008   # apply a single numbered file
#
# psql runs inside the container, so nothing is needed on the host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env
PGUSER_="${PGUSER:-postgres}"
PGDATABASE_="${PGDATABASE:-cdntaxpractice}"
SERVICE="postgres"

SKIP_SEED=0
RUN_VERIFY=1
ONLY=""
while (( $# )); do
  case "$1" in
    --skip-seed) SKIP_SEED=1 ;;
    --no-verify) RUN_VERIFY=0 ;;
    --only)      ONLY="${2:-}"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }

if ! docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx "$SERVICE"; then
  log "Starting $SERVICE"
  docker compose up -d "$SERVICE" >/dev/null
fi

deadline=$(( SECONDS + 120 ))
until docker compose exec -T "$SERVICE" pg_isready -U "$PGUSER_" -d "$PGDATABASE_" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then err "PostgreSQL not ready"; exit 1; fi
  sleep 2
done

# ON_ERROR_STOP makes psql exit non-zero on the first failing statement instead
# of ploughing on and reporting a misleading cascade of dependency errors.
run_file() {
  local file="$1" base
  base="$(basename "$file")"
  printf '    %-34s' "$base"
  local out
  if out=$(docker compose exec -T "$SERVICE" psql \
             -U "$PGUSER_" -d "$PGDATABASE_" \
             -v ON_ERROR_STOP=1 --quiet --no-psqlrc \
             -f "/db/postgres/$base" 2>&1); then
    printf 'ok\n'
    if [[ "$base" == 099_* && -n "$out" ]]; then
      printf '%s\n' "$out" | sed 's/^/        /'
    fi
  else
    printf 'FAILED\n'
    printf '%s\n' "$out" | sed 's/^/        /' >&2
    return 1
  fi
}

if [[ -n "$ONLY" ]]; then
  f=$(ls db/postgres/${ONLY}_*.sql 2>/dev/null | head -1)
  [[ -z "$f" ]] && { err "no file matching db/postgres/${ONLY}_*.sql"; exit 1; }
  log "Applying $(basename "$f")"
  run_file "$f"
  exit $?
fi

log "Applying schema"
for f in db/postgres/0[0-1]*.sql; do
  run_file "$f"
done

if (( SKIP_SEED )); then
  log "Skipping seed data (--skip-seed)"
else
  log "Seeding reference data"
  for f in db/postgres/02*.sql; do
    [[ -e "$f" ]] || continue
    run_file "$f"
  done
fi

if (( RUN_VERIFY )) && [[ -f db/postgres/099_verify.sql ]]; then
  log "Verifying"
  run_file db/postgres/099_verify.sql
fi

log "Done. Connect with: psql -h localhost -p 15432 -U $PGUSER_ -d $PGDATABASE_"
