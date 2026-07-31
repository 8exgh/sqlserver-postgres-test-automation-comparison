#!/usr/bin/env bash
#
# Installs and registers everything the C++ report tool needs to talk to both
# databases, then proves both connections work before any code is built.
#
#   scripts/setup-odbc.sh            # install what is missing, register, verify
#   scripts/setup-odbc.sh --verify   # only run the connectivity checks
#
# PostgreSQL needs nothing installed here: libpq arrives with the postgresql
# formula and is linked directly. SQL Server goes through unixODBC, which will
# not find the FreeTDS driver on its own - the driver has to be written into
# odbcinst.ini, which is what this script exists for.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env
SS_PASSWORD="${MSSQL_SA_PASSWORD:-Str0ng!Passw0rd}"
PG_PASSWORD="${PGPASSWORD:-Str0ng!Passw0rd}"

VERIFY_ONLY=0
[[ "${1:-}" == "--verify" ]] && VERIFY_ONLY=1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[1;32m%-22s\033[0m %s\n' "$1" "${2:-}"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }

if ! command -v brew >/dev/null 2>&1; then
  err "Homebrew is required to install unixODBC and FreeTDS."
  exit 1
fi

#--- install ------------------------------------------------------------------
if (( ! VERIFY_ONLY )); then
  log "Installing build and driver dependencies"
  for f in cmake unixodbc freetds postgresql@14; do
    if brew list --formula "$f" >/dev/null 2>&1; then
      ok "$f" "already installed"
    else
      printf '    installing %s ...\n' "$f"
      brew install "$f" >/dev/null
      ok "$f" "installed"
    fi
  done
fi

FREETDS_PREFIX="$(brew --prefix freetds)"
ODBC_DRIVER="$FREETDS_PREFIX/lib/libtdsodbc.so"

if [[ ! -f "$ODBC_DRIVER" ]]; then
  err "FreeTDS ODBC driver not found at $ODBC_DRIVER"
  err "FreeTDS must be built with unixODBC support (the Homebrew bottle is)."
  exit 1
fi

#--- register the driver with unixODBC ---------------------------------------
if (( ! VERIFY_ONLY )); then
  log "Registering the FreeTDS driver with unixODBC"
  # odbcinst writes to whichever odbcinst.ini it was compiled to use, which is
  # why the path is read back from odbcinst rather than assumed.
  tmpl="$(mktemp)"
  cat > "$tmpl" <<EOF
[FreeTDS]
Description = FreeTDS driver for Microsoft SQL Server
Driver      = $ODBC_DRIVER
EOF
  odbcinst -i -d -f "$tmpl" >/dev/null
  rm -f "$tmpl"
  ok "odbcinst.ini" "$(odbcinst -j | awk -F': *' '/^DRIVERS/{print $2}')"
  ok "drivers" "$(odbcinst -q -d | tr -d '[]' | tr '\n' ' ')"
fi

#--- verify both connections --------------------------------------------------
log "Verifying connectivity"

SS_HOST="${MSSQL_HOST:-localhost}"; SS_PORT="${MSSQL_PORT:-11433}"
SS_DB="${MSSQL_DB:-CdnTaxPractice}"; SS_USER="${MSSQL_USER:-sa}"
PG_HOST="${PGHOST:-localhost}";      PG_PORT="${PGPORT:-15432}"
PG_DB="${PGDATABASE:-cdntaxpractice}"; PG_USER="${PGUSER:-postgres}"

rc=0

# SQL Server, through the same ODBC path the C++ tool will use.
CONN="DRIVER={FreeTDS};SERVER=$SS_HOST;PORT=$SS_PORT;DATABASE=$SS_DB;UID=$SS_USER;PWD=$SS_PASSWORD;TDS_Version=7.4"
if out=$(printf 'SELECT COUNT(*) FROM tax.T1Return\n' | isql -v -k "$CONN" -b 2>&1); then
  # isql prints a boxed result; pull the first bare integer out of it. The
  # `|| true` matters: grep exits 1 when it matches nothing and, under
  # `set -o pipefail`, that status would escape the assignment and `set -e`
  # would kill the script exactly when there is nothing wrong.
  n="$(printf '%s' "$out" | tr -d '| ' | grep -xE '[0-9]+' | head -1 || true)"
  ok "sqlserver (ODBC)" "$SS_HOST:$SS_PORT/$SS_DB - ${n:-?} T1 returns"
else
  err "SQL Server connection failed:"; printf '%s\n' "$out" | sed 's/^/      /' >&2; rc=1
fi

# PostgreSQL, using psql only as a reachability check - the tool itself uses libpq.
if command -v psql >/dev/null 2>&1; then
  if n=$(PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
           -tA --no-psqlrc -c 'SELECT count(*) FROM tax.t1return' 2>/dev/null); then
    ok "postgres (libpq)" "$PG_HOST:$PG_PORT/$PG_DB - ${n} T1 returns"
  else
    err "PostgreSQL connection failed ($PG_HOST:$PG_PORT/$PG_DB)"; rc=1
  fi
else
  warn "psql not on PATH; skipping the PostgreSQL reachability check"
fi

if (( rc )); then
  err ""
  err "Bring the databases up with:  docker compose up -d"
  exit 1
fi

log "Ready. Build with: cmake -S app -B app/build && cmake --build app/build"
