#!/usr/bin/env bash
#
# Runs the T1 assessment register against both engines and diffs the CSV.
#
# This is the cross-engine check the whole repo is aimed at: identical output
# from the legacy SQL Server and the migrated PostgreSQL is evidence the port
# preserved behaviour at the application layer, not just at the schema level.
#
#   scripts/run-report.sh                # 2024, both engines, diff
#   scripts/run-report.sh --year 2023
#   scripts/run-report.sh --province ON
#   scripts/run-report.sh --show         # also print the text report
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

YEAR=2024
PROVINCE=""
SHOW=0
while (( $# )); do
  case "$1" in
    --year)     YEAR="${2:-}"; shift ;;
    --province) PROVINCE="${2:-}"; shift ;;
    --show)     SHOW=1 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }

BIN="app/build/t1report"
if [[ ! -x "$BIN" ]]; then
  log "Building"
  cmake -S app -B app/build -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build app/build >/dev/null
fi

ARGS=(--year "$YEAR" --format csv)
[[ -n "$PROVINCE" ]] && ARGS+=(--province "$PROVINCE")

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

log "Running the register for $YEAR${PROVINCE:+ (province $PROVINCE)}"

for engine in postgres sqlserver; do
  if ! "$BIN" --engine "$engine" "${ARGS[@]}" > "$OUT/$engine.csv" 2> "$OUT/$engine.err"; then
    rc=$?
    err "$engine failed (exit $rc)"
    sed 's/^/    /' "$OUT/$engine.err" >&2
    exit "$rc"
  fi
  rows="$(( $(wc -l < "$OUT/$engine.csv") - 2 ))"   # minus header and TOTAL
  printf '    %-10s %s rows\n' "$engine" "$rows"
done

echo ""
if diff -u "$OUT/postgres.csv" "$OUT/sqlserver.csv" > "$OUT/diff.txt"; then
  log "MATCH - both engines produced byte-identical output"
  printf '    sha256 %s\n' "$(shasum -a 256 < "$OUT/postgres.csv" | cut -d' ' -f1)"
  printf '    %s\n' "$(tail -1 "$OUT/postgres.csv")"
else
  err "MISMATCH - the two engines disagree"
  sed 's/^/    /' "$OUT/diff.txt" >&2
  exit 1
fi

if (( SHOW )); then
  echo ""
  SHOW_ARGS=(--year "$YEAR")
  [[ -n "$PROVINCE" ]] && SHOW_ARGS+=(--province "$PROVINCE")
  "$BIN" --engine postgres "${SHOW_ARGS[@]}"
fi
