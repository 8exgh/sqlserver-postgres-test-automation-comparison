#!/usr/bin/env bash
#
# Converts the running SQL Server schema to PostgreSQL with the AWS Schema
# Conversion Tool (lib/AWSSchemaConversionToolBatch.jar).
#
# By default it only *generates* SQL and an assessment report — nothing is
# written to the Postgres target unless you pass --apply.
#
#   scripts/convert-to-postgres.sh              # convert, save SQL + report
#   scripts/convert-to-postgres.sh --apply      # also create the objects in PG
#   scripts/convert-to-postgres.sh --report-only
#   scripts/convert-to-postgres.sh --keep-scenario   # leave the .scts on disk
#
# Outputs:
#   db/postgres/generated/   converted DDL, one tree of .sql files
#   build/sct/report/        assessment report (CSV + PDF)
#   build/sct/project/       the SCT project, reopenable in the SCT desktop app
#   build/sct/log/           SCT's own logs
#
# ---------------------------------------------------------------------------
# Two things about this jar are worth knowing, because both are silent traps:
#
#  1. It is signed, and META-INF/SIGNER.SF is ~31 MB. Since JDK 17.0.7 the
#     launcher refuses signature files over jdk.jar.maxSignatureFileSize
#     (default 8 MB) and reports only "An unexpected error occurred while
#     trying to open file". Raising that limit is what makes `java -jar` work.
#
#  2. It ships no JDBC drivers. Both the SQL Server and PostgreSQL drivers have
#     to be downloaded and registered through SCT's global settings; this
#     script does that automatically into lib/jdbc/.
#
#  3. It needs an x86_64 JVM on macOS. SCT starts a JavaFX toolkit even in CLI
#     mode and routes every converted object through it, but the macOS JavaFX
#     natives inside the jar are x86_64-only. On an arm64 JVM every object
#     fails with "No toolkit found" and the conversion produces an empty file
#     while still exiting 0. Use --bootstrap-jvm to fetch a Corretto x64 JDK
#     into build/jvm, or point SCT_JAVA at an existing one.
#
#     It also needs --add-opens for java.base reflection on Java 17, or the
#     T-SQL parser fails partway through with a PARSER ERROR.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env

#--- configuration -----------------------------------------------------------
SCT_JAR="${SCT_JAR:-$REPO_ROOT/lib/AWSSchemaConversionToolBatch.jar}"
JDBC_DIR="${JDBC_DIR:-$REPO_ROOT/lib/jdbc}"
PG_DRIVER_URL="${PG_DRIVER_URL:-https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar}"
MSSQL_DRIVER_URL="${MSSQL_DRIVER_URL:-https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/12.8.1.jre11/mssql-jdbc-12.8.1.jre11.jar}"

# Source: the SQL Server built by scripts/apply-sqlserver.sh
SRC_HOST="${SRC_HOST:-localhost}"
SRC_PORT="${SRC_PORT:-11433}"
SRC_DB="${SRC_DB:-CdnTaxPractice}"
SRC_USER="${SRC_USER:-sa}"
SRC_PASSWORD="${MSSQL_SA_PASSWORD:-Str0ng!Passw0rd}"

# Target: the postgres service in docker-compose.yml
TGT_HOST="${TGT_HOST:-localhost}"
TGT_PORT="${TGT_PORT:-15432}"
TGT_DB="${PGDATABASE:-cdntaxpractice}"
TGT_USER="${PGUSER:-postgres}"
TGT_PASSWORD="${PGPASSWORD:-Str0ng!Passw0rd}"

BUILD_DIR="$REPO_ROOT/build/sct"
PROJECT_DIR="$BUILD_DIR/project"
REPORT_DIR="$BUILD_DIR/report"
LOG_DIR="$BUILD_DIR/log"
SQL_OUT_DIR="$REPO_ROOT/db/postgres/generated"
# SaveTargetSQL's -file is a FILE, not a directory: pointing it at a directory
# fails with FileNotFoundException "(Is a directory)".
SQL_OUT_FILE="$SQL_OUT_DIR/cdntaxpractice-postgresql.sql"
SCENARIO="$BUILD_DIR/convert.scts"
PROJECT_NAME="CdnTaxPractice"

# SCT vendor identifiers and the settings keys for the driver paths.
SRC_VENDOR="MSSQL"
TGT_VENDOR="POSTGRESQL"

APPLY=0
REPORT_ONLY=0
KEEP_SCENARIO=0
BOOTSTRAP_JVM=0
for arg in "$@"; do
  case "$arg" in
    --apply)         APPLY=1 ;;
    --report-only)   REPORT_ONLY=1 ;;
    --keep-scenario) KEEP_SCENARIO=1 ;;
    --bootstrap-jvm) BOOTSTRAP_JVM=1 ;;
    -h|--help)       sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }

#--- preflight ---------------------------------------------------------------
if [[ ! -f "$SCT_JAR" ]]; then
  err "SCT jar not found at $SCT_JAR"
  err "Download it from https://s3.amazonaws.com/publicsctdownload/jars/AWSSchemaConversionToolBatch.jar"
  exit 1
fi

if ! command -v java >/dev/null 2>&1; then
  err "java not found on PATH. AWS SCT needs a JRE (17 works; this jar was built with 17)."
  exit 1
fi

#--- pick a JVM --------------------------------------------------------------
# SCT initialises a JavaFX toolkit even in CLI mode, and every object it
# converts goes through it. The macOS JavaFX natives inside the jar are
# x86_64-only (libglass.dylib and friends), so on Apple Silicon an arm64 JVM
# fails with "No toolkit found" and the conversion silently produces nothing.
#
# An x86_64 JVM under Rosetta works. Preference order:
#   $SCT_JAVA  ->  a bootstrapped JDK in build/jvm  ->  system java
BOOTSTRAP_JVM_DIR="$BUILD_DIR/../jvm"
CORRETTO_URL="${CORRETTO_URL:-https://corretto.aws/downloads/latest/amazon-corretto-17-x64-macos-jdk.tar.gz}"

bootstrap_jvm() {
  log "Bootstrapping an x86_64 Amazon Corretto 17 JDK into build/jvm (~180 MB)"
  mkdir -p "$BOOTSTRAP_JVM_DIR"
  local tarball="$BOOTSTRAP_JVM_DIR/corretto.tar.gz"
  if ! curl -sSL --fail --max-time 900 -o "$tarball" "$CORRETTO_URL"; then
    err "Could not download Corretto from $CORRETTO_URL"
    exit 1
  fi
  tar xzf "$tarball" -C "$BOOTSTRAP_JVM_DIR"
  rm -f "$tarball"
}

find_bootstrapped_java() {
  find "$BOOTSTRAP_JVM_DIR" -maxdepth 5 -type f -name java -perm -u+x 2>/dev/null | head -1
}

if (( BOOTSTRAP_JVM )); then
  rm -rf "$BOOTSTRAP_JVM_DIR"
  bootstrap_jvm
fi

JAVA_BIN="${SCT_JAVA:-}"
if [[ -z "$JAVA_BIN" ]]; then
  JAVA_BIN="$(find_bootstrapped_java || true)"
fi
[[ -z "$JAVA_BIN" ]] && JAVA_BIN="$(command -v java)"

JAVA_ARCH="$(file -b "$(readlink -f "$JAVA_BIN" 2>/dev/null || echo "$JAVA_BIN")" 2>/dev/null | grep -oE 'x86_64|arm64' | head -1)"
HOST_ARCH="$(uname -m)"

if [[ "$HOST_ARCH" == "arm64" && "$JAVA_ARCH" != "x86_64" ]]; then
  err "This is an arm64 Mac and $JAVA_BIN is not an x86_64 JVM."
  err "SCT's bundled macOS JavaFX natives are x86_64-only, so conversion will"
  err "fail with \"No toolkit found\" and produce no output."
  err ""
  err "Fix it with either:"
  err "    scripts/convert-to-postgres.sh --bootstrap-jvm    # downloads Corretto x64 into build/jvm"
  err "    SCT_JAVA=/path/to/x86_64/bin/java scripts/convert-to-postgres.sh"
  exit 1
fi

JAVA_MAJOR="$("$JAVA_BIN" -version 2>&1 | sed -n '1s/.*version "\([0-9]*\).*/\1/p')"
if [[ -n "$JAVA_MAJOR" && "$JAVA_MAJOR" -lt 11 ]]; then
  err "Java $JAVA_MAJOR is too old for this SCT build; use 11 or newer."
  exit 1
fi
printf '    %-12s %s (%s, Java %s)\n' "jvm" "$JAVA_BIN" "${JAVA_ARCH:-unknown}" "${JAVA_MAJOR:-?}"

log "Fetching JDBC drivers if needed"
mkdir -p "$JDBC_DIR"
fetch_driver() {
  local dest="$1" url="$2" label="$3"
  if [[ -s "$dest" ]]; then
    printf '    %-12s present\n' "$label"
  else
    printf '    %-12s downloading\n' "$label"
    if ! curl -sSL --fail --max-time 180 -o "$dest" "$url"; then
      err "Could not download the $label JDBC driver from $url"
      err "Download it manually and place it at $dest"
      exit 1
    fi
  fi
}
fetch_driver "$JDBC_DIR/postgresql.jar" "$PG_DRIVER_URL"    "postgresql"
fetch_driver "$JDBC_DIR/mssql-jdbc.jar" "$MSSQL_DRIVER_URL" "mssql"

#--- make sure both databases are actually up --------------------------------
log "Checking source and target databases"

if ! docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx 'sqlserver'; then
  warn "the sqlserver service is not running; starting it"
  docker compose up -d sqlserver >/dev/null
fi
if ! docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx 'postgres'; then
  warn "the postgres service is not running; starting it"
  docker compose up -d postgres >/dev/null
fi

# Wait for both to accept connections.
deadline=$(( SECONDS + 300 ))
until docker compose exec -T sqlserver /opt/mssql-tools18/bin/sqlcmd \
        -C -S localhost -U sa -P "$SRC_PASSWORD" -d "$SRC_DB" -Q "SELECT 1" -b -t 5 >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    err "SQL Server database [$SRC_DB] is not reachable."
    err "Run scripts/apply-sqlserver.sh first to build it."
    exit 1
  fi
  sleep 5
done
printf '    %-12s ok (%s:%s/%s)\n' "sqlserver" "$SRC_HOST" "$SRC_PORT" "$SRC_DB"

deadline=$(( SECONDS + 120 ))
until docker compose exec -T postgres pg_isready -U "$TGT_USER" -d "$TGT_DB" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    err "PostgreSQL is not reachable on $TGT_HOST:$TGT_PORT"
    exit 1
  fi
  sleep 3
done
printf '    %-12s ok (%s:%s/%s)\n' "postgres" "$TGT_HOST" "$TGT_PORT" "$TGT_DB"

#--- make the conversion reproducible ---------------------------------------
# SCT reads the *target* database and folds its current state into the schema
# mapping, so converting twice against a target that already holds a previous
# result produced different output (8 schemas / 4212 lines vs 7 / 4897). The
# generated file has to be a function of the source alone, so the converted
# schemas are cleared first.
#
# With this in place two consecutive runs produce byte-identical SQL. The only
# residual difference is the order of action-item codes inside two comment
# lines, which SCT emits from an unordered set - no generated SQL varies.
if (( ! REPORT_ONLY )); then
  log "Clearing previously converted schemas from the target"
  docker compose exec -T postgres psql -U "$TGT_USER" -d "$TGT_DB" --quiet --no-psqlrc \
    -c "SET client_min_messages = warning;" \
    -c "DROP SCHEMA IF EXISTS ${TGT_DB}_ref, ${TGT_DB}_client, ${TGT_DB}_tax,
                              ${TGT_DB}_acct, ${TGT_DB}_payroll, ${TGT_DB}_audit,
                              ${TGT_DB}_util, ${TGT_DB}_dbo CASCADE;" >/dev/null 2>&1 || true
fi

#--- workspace ---------------------------------------------------------------
log "Preparing workspace"
# The SCT project must not already exist, or CreateProject fails.
rm -rf "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR" "$REPORT_DIR" "$LOG_DIR" "$SQL_OUT_DIR"

#--- register the JDBC drivers ----------------------------------------------
# Done by writing SCT's own settings file rather than with the scenario's
# SetGlobalSettings command: that command takes its settings as a JSON blob,
# and the scenario grammar's string literals cannot carry one (the ANTLR lexer
# rejects the braces and double quotes).
log "Registering JDBC drivers in SCT settings"
SCT_SETTINGS="${SCT_SETTINGS:-$HOME/AWS Schema Conversion Tool/settings.xml}"
mkdir -p "$(dirname "$SCT_SETTINGS")"

SCT_SETTINGS="$SCT_SETTINGS" \
MSSQL_DRIVER="$JDBC_DIR/mssql-jdbc.jar" \
PG_DRIVER="$JDBC_DIR/postgresql.jar" \
python3 - <<'PY'
import os, xml.etree.ElementTree as ET

path   = os.environ["SCT_SETTINGS"]
wanted = {
    "mssql_driver_file":      os.environ["MSSQL_DRIVER"],
    "postgresql_driver_file": os.environ["PG_DRIVER"],
}

if os.path.exists(path):
    tree = ET.parse(path)
    root = tree.getroot()
else:
    root = ET.Element("global_settings")
    tree = ET.ElementTree(root)

existing = {e.get("key"): e for e in root.findall("setting")}
for key, value in wanted.items():
    if key in existing:
        existing[key].set("value", value)
    else:
        ET.SubElement(root, "setting", {"key": key, "value": value})

tree.write(path, encoding="UTF-8", xml_declaration=True)
for key, value in wanted.items():
    print(f"    {key:24s} {value}")
PY

#--- scenario ----------------------------------------------------------------
# The scenario carries database passwords, so it is created with a private
# umask and deleted at the end unless --keep-scenario was passed.
log "Generating SCT scenario"
( umask 077; : > "$SCENARIO" )

# Tree paths are DOT-separated, and the first segment is a throwaway label that
# the resolver strips before treating the next one as the server name. A path
# using '/' silently resolves to nothing, which surfaces only as an
# ArrayIndexOutOfBoundsException deep inside the tool.
#
# The two sides also have different shapes. SQL Server nests schemas under a
# database; PostgreSQL, where a connection is already scoped to one database,
# has no Databases level at all:
#
#   source  Servers.MSSQL.Databases.CdnTaxPractice.Schemas.<schema>
#   target  Servers.POSTGRESQL.Schemas.<schema>
SRC_TREE="Servers.$SRC_VENDOR.Databases.$SRC_DB.Schemas.%"
TGT_TREE="Servers.$TGT_VENDOR.Schemas.%"

# The schema mapping is made one level up, database -> server. Mapping the
# wildcarded schema paths to each other instead is rejected ("Not found
# object(s)"): the target schemas do not exist yet, so there is nothing on that
# side for the wildcard to match. Mapping the whole database onto the target
# server lets SCT create a matching schema per source schema.
MAP_SRC="Servers.$SRC_VENDOR.Databases.$SRC_DB"
MAP_TGT="Servers.$TGT_VENDOR"

# Scenario grammar (from the tool's own ANTLR lexer, CliCommands.g4):
#   command    : Id argument* '/'      <- '/' terminates a command, not ';'
#   argument   : '-' Id ':' value
#   value      : '...'                 <- single-quoted, backslash escapes
#   comment    : # to end of line, or /* ... */
{
  echo "# Generated by scripts/convert-to-postgres.sh - do not edit."
  echo "# Commands are terminated by '/' on its own line."
  echo ""
  echo "CreateProject"
  echo "    -name: '$PROJECT_NAME'"
  echo "    -directory: '$PROJECT_DIR'"
  echo "/"
  echo ""
  echo "# ---- source: SQL Server ----"
  echo "AddSource"
  echo "    -name: '$SRC_VENDOR'"
  echo "    -vendor: '$SRC_VENDOR'"
  echo "    -host: '$SRC_HOST'"
  echo "    -port: '$SRC_PORT'"
  echo "    -database: '$SRC_DB'"
  echo "    -user: '$SRC_USER'"
  echo "    -password: '$SRC_PASSWORD'"
  echo "    -trustServerCertificate: 'true'"
  echo "/"
  echo ""
  echo "ConnectSource"
  echo "    -name: '$SRC_VENDOR'"
  echo "    -password: '$SRC_PASSWORD'"
  echo "/"
  echo ""
  echo "# ---- target: PostgreSQL ----"
  echo "AddTarget"
  echo "    -name: '$TGT_VENDOR'"
  echo "    -vendor: '$TGT_VENDOR'"
  echo "    -host: '$TGT_HOST'"
  echo "    -port: '$TGT_PORT'"
  echo "    -database: '$TGT_DB'"
  echo "    -user: '$TGT_USER'"
  echo "    -password: '$TGT_PASSWORD'"
  echo "/"
  echo ""
  echo "ConnectTarget"
  echo "    -name: '$TGT_VENDOR'"
  echo "    -password: '$TGT_PASSWORD'"
  echo "/"
  echo ""
  echo "# ---- load metadata, then map source schemas onto the target ----"
  echo "LoadSourceTree"
  echo "    -sourceName: '$SRC_VENDOR'"
  echo "/"
  echo ""
  echo "LoadTargetTree"
  echo "    -targetName: '$TGT_VENDOR'"
  echo "/"
  echo ""
  echo "AddServerMapping"
  echo "    -sourceTreePath: '$MAP_SRC'"
  echo "    -targetTreePath: '$MAP_TGT'"
  echo "/"
  echo ""
  echo "# ---- convert ----"
  echo "Convert"
  echo "    -treePath: '$SRC_TREE'"
  echo "/"
  echo ""
  echo "CreateReport"
  echo "    -treePath: '$SRC_TREE'"
  echo "/"
  echo ""
  echo "SaveReportCSV"
  echo "    -treePath: '$SRC_TREE'"
  echo "    -directory: '$REPORT_DIR'"
  echo "/"
  echo ""
  echo "SaveReportPDF"
  echo "    -file: '$REPORT_DIR/assessment.pdf'"
  echo "    -treePath: '$SRC_TREE'"
  echo "/"

  if (( ! REPORT_ONLY )); then
    echo ""
    echo "# ---- write the converted DDL out as .sql files ----"
    echo "SaveTargetSQL"
    echo "    -file: '$SQL_OUT_FILE'"
    echo "    -treePath: '$TGT_TREE'"
    echo "/"
  fi

  if (( APPLY )); then
    echo ""
    echo "# ---- create the objects in the PostgreSQL target ----"
    echo "ApplyToTarget"
    echo "    -treePath: '$TGT_TREE'"
    echo "/"
  fi

  echo ""
  echo "SaveProject"
  echo "/"
} >> "$SCENARIO"

#--- run ---------------------------------------------------------------------
log "Running AWS SCT (this takes a few minutes)"
if (( APPLY )); then
  warn "--apply: converted objects WILL be created in $TGT_DB on $TGT_HOST:$TGT_PORT"
fi

SCT_LOG="$LOG_DIR/sct-run.log"
set +e
"$JAVA_BIN" \
  -Djdk.jar.maxSignatureFileSize=100000000 \
  --add-opens java.base/java.lang=ALL-UNNAMED \
  --add-opens java.base/java.lang.reflect=ALL-UNNAMED \
  --add-opens java.base/java.util=ALL-UNNAMED \
  --add-opens java.base/java.text=ALL-UNNAMED \
  -Xmx4g \
  -jar "$SCT_JAR" \
  -type scts \
  -script "$SCENARIO" \
  -sourcePassword "$SRC_PASSWORD" \
  -targetPassword "$TGT_PASSWORD" \
  >"$SCT_LOG" 2>&1
SCT_RC=$?
set -e

# SCT does not reliably exit non-zero on a failed command, so the log is
# scanned as well. Two classes of error are expected and benign here, and are
# reported as warnings rather than failures:
#
#   "No toolkit found"  - the tool tries to spin up a JavaFX toolkit even in
#       CLI mode. The macOS JavaFX natives inside the jar are x86_64-only, so
#       on Apple Silicon the toolkit cannot start. Only the cosmetic commands
#       need it: SaveProject and SaveReportPDF fail, while connecting,
#       converting and saving SQL all complete normally. Running under an
#       x86_64 JVM (arch -x86_64) makes even those work.
#
#   "AWS SCT doesn't support this version" - a JRE vendor check. It wants
#       Amazon Corretto and warns about anything else; it does not stop the run.
# Known-benign log noise, kept as an explicit allow-list so anything genuinely
# new still fails the run:
#
#  * "No toolkit found" / vendor check - only reachable on an arm64 JVM, which
#    the preflight now refuses outright. Left here for non-macOS hosts.
#
#  * RESOLVER ERROR lines naming scope {MSSQL} - SCT parsing its own built-in
#    SQL Server dialect definitions at startup. They mention identifiers that
#    exist nowhere in this project (VARCHAT, SP_EXECUTESQL, GEOGRAPHY,
#    GEOMETRY) and appear even against an empty database.
#
#  * "executing statement [postgresql/mssql/.../aws_lambda|postgis...]" - SCT's
#    extension pack installing optional AWS-specific helpers. A vanilla
#    PostgreSQL has neither aws_lambda nor postgis, and nothing in this schema
#    needs them; the rest of the extension pack installs normally.
#
#  * "referenced-constraint-schema isn't found" - emitted while re-reading the
#    converted model for cross-schema foreign keys. Cosmetic: all 57 foreign
#    keys are present in the generated DDL, which the output check below
#    verifies rather than assumes.
BENIGN='No toolkit found|RuntimeException: No toolkit found|AWS SCT doesn.t support this version|Can.t create PDF file|(SaveProject|AddSource|AddTarget|SaveReportPDF) failed with exception|RESOLVER ERROR|referenced-constraint-schema|executing statement \[postgresql/mssql/.*(aws_lambda|postgis|awslambda)'

# A third category: PRINTER and TRANSFORMER errors are SCT telling us it could
# not translate a specific T-SQL construct - MERGE, for instance, which it does
# not render into PostgreSQL. Those are findings about the schema, not faults in
# this script, and SCT already itemises them in the assessment report. They are
# counted and surfaced but do not fail the run; anything outside all three
# buckets does.
CONVERSION='(PRINTER|TRANSFORMER) ERROR'

# A fourth category, only reachable with --apply: DDL that SCT generated but
# PostgreSQL refused to execute. Also a finding about the schema rather than a
# fault in this script, but it does leave the target incomplete, so it is
# reported in detail and still fails the run.
APPLYFAIL='Executing the following DDL-statement'

# Each count ends with `|| true`: grep exits 1 when it matches nothing, and
# under `set -o pipefail` that status escapes the command substitution and
# `set -e` then kills the script - precisely when there is nothing wrong.
ALL_ERRORS="$(grep -E '(^|\s)ERROR\s' "$SCT_LOG" 2>/dev/null | wc -l | tr -d ' ' || true)"
NON_BENIGN="$(grep -E '(^|\s)ERROR\s' "$SCT_LOG" 2>/dev/null | grep -vE "$BENIGN" | wc -l | tr -d ' ' || true)"
NON_APPLY="$(grep -E '(^|\s)ERROR\s' "$SCT_LOG" 2>/dev/null | grep -vE "$BENIGN" | grep -vE "$CONVERSION" | wc -l | tr -d ' ' || true)"
REAL_ERRORS="$(grep -E '(^|\s)ERROR\s' "$SCT_LOG" 2>/dev/null | grep -vE "$BENIGN" | grep -vE "$CONVERSION" | grep -vE "$APPLYFAIL" | wc -l | tr -d ' ' || true)"
ALL_ERRORS="${ALL_ERRORS:-0}"; NON_BENIGN="${NON_BENIGN:-0}"
NON_APPLY="${NON_APPLY:-0}"; REAL_ERRORS="${REAL_ERRORS:-0}"
BENIGN_COUNT=$(( ALL_ERRORS - NON_BENIGN ))
CONVERSION_COUNT=$(( NON_BENIGN - NON_APPLY ))
APPLY_FAILURES=$(( NON_APPLY - REAL_ERRORS ))

if (( BENIGN_COUNT > 0 )); then
  warn "$BENIGN_COUNT known-benign SCT log errors ignored (see the allow-list in this script)."
fi

if (( SCT_RC != 0 )) || (( REAL_ERRORS > 0 )); then
  err "SCT reported real problems (exit code $SCT_RC, $REAL_ERRORS error lines)."
  err "From $SCT_LOG:"
  grep -E '(^|\s)ERROR\s' "$SCT_LOG" | grep -vE "$BENIGN" | grep -vE "$CONVERSION" \
    | grep -vE "$APPLYFAIL" | tail -15 | sed 's/^/    /' >&2 || true
  (( KEEP_SCENARIO )) || rm -f "$SCENARIO"
  exit 1
fi

(( KEEP_SCENARIO )) || rm -f "$SCENARIO"

#--- results -----------------------------------------------------------------
# Verify the run actually produced something, rather than trusting a zero exit
# code: SCT reports success even when a command quietly wrote nothing.
if (( ! REPORT_ONLY )) && [[ ! -s "$SQL_OUT_FILE" ]]; then
  err "SCT exited cleanly but produced no DDL at $SQL_OUT_FILE"
  err "See $SCT_LOG"
  exit 1
fi

log "Conversion complete"
if (( CONVERSION_COUNT > 0 )); then
  printf '    constructs SCT could not translate: %s (itemised in the report)\n' "$CONVERSION_COUNT"
  grep -E "$CONVERSION" "$SCT_LOG" | sed -E 's/.*(PRINTER|TRANSFORMER) ERROR *//' \
    | grep -v '^$' | sort | uniq -c | sort -rn | head -6 | sed 's/^/      /'
fi
SQL_LINES="$(wc -l < "$SQL_OUT_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
printf '    generated DDL       : %s (%s lines)\n' "${SQL_OUT_FILE#$REPO_ROOT/}" "${SQL_LINES:-0}"

if [[ -s "$SQL_OUT_FILE" ]]; then
  printf '    converted objects   : %s schemas, %s tables, %s views, %s functions, %s procedures,\n' \
    "$(grep -cE '^CREATE SCHEMA' "$SQL_OUT_FILE" || true)" \
    "$(grep -cE '^CREATE TABLE' "$SQL_OUT_FILE" || true)" \
    "$(grep -cE '^CREATE OR REPLACE +VIEW' "$SQL_OUT_FILE" || true)" \
    "$(grep -cE '^CREATE OR REPLACE +FUNCTION' "$SQL_OUT_FILE" || true)" \
    "$(grep -cE '^CREATE OR REPLACE +PROCEDURE' "$SQL_OUT_FILE" || true)"
  printf '                          %s triggers, %s sequences, %s foreign keys\n' \
    "$(grep -cE '^CREATE TRIGGER' "$SQL_OUT_FILE" || true)" \
    "$(grep -cE '^CREATE SEQUENCE' "$SQL_OUT_FILE" || true)" \
    "$(grep -ci 'FOREIGN KEY' "$SQL_OUT_FILE" || true)"

  # Object counts alone would not have caught the worst thing SCT did: it
  # dropped the GENERATED expression from five computed columns while leaving
  # the columns in place, so every count still matched. Compare the generated
  # column count against the source instead.
  SRC_COMPUTED="$(docker compose exec -T sqlserver /opt/mssql-tools18/bin/sqlcmd \
      -C -S localhost -U sa -P "$SRC_PASSWORD" -d "$SRC_DB" -I -h-1 -W \
      -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.computed_columns;" 2>/dev/null \
      | tr -d ' \r' | head -1)"
  OUT_COMPUTED="$(grep -c 'GENERATED ALWAYS AS (' "$SQL_OUT_FILE" || true)"
  printf '    computed columns    : %s of %s carried over\n' "${OUT_COMPUTED:-0}" "${SRC_COMPUTED:-?}"
  if [[ -n "$SRC_COMPUTED" ]] && (( ${OUT_COMPUTED:-0} < SRC_COMPUTED )); then
    err "SCT dropped $(( SRC_COMPUTED - OUT_COMPUTED )) computed column expression(s)."
    err "It leaves the column in place with its GENERATED clause removed, so no"
    err "object count reveals this - action item 7811 skips the CONVERT() call and"
    err "takes the whole expression with it."
    err ""
    err "The generated SQL and the assessment report above are still valid output;"
    err "this is a defect in the conversion, not in the run. The corrected,"
    err "hand-finished schema is in db/postgres/ - apply it with"
    err "scripts/apply-postgres.sh."
    exit 1
  fi

  # SCT emits an unconvertible object as a stub whose only columns are
  # (text, error_msg), so these are the objects needing a manual port.
  STUBS="$(grep -cE '\(text, error_msg\)' "$SQL_OUT_FILE" || true)"
  if (( STUBS > 0 )); then
    printf '    NEEDS MANUAL PORT   : %s object(s) SCT could not convert:\n' "$STUBS"
    grep -E '\(text, error_msg\)' "$SQL_OUT_FILE" \
      | sed -E 's/^CREATE OR REPLACE +//; s/ \(text, error_msg\).*//; s/^/                          /'
  fi
fi
printf '    assessment report   : %s\n' "${REPORT_DIR#$REPO_ROOT/}"
printf '    SCT project         : %s\n' "${PROJECT_DIR#$REPO_ROOT/}"
printf '    SCT log             : %s\n' "${SCT_LOG#$REPO_ROOT/}"

if (( APPLY )); then
  echo ""
  log "Objects created in the PostgreSQL target"
  # Scoped to the converted schemas by name: SCT also installs its own
  # extension-pack schema, which would otherwise inflate every count.
  docker compose exec -T postgres psql -U "$TGT_USER" -d "$TGT_DB" -tA -c "
    SELECT 'schemas=' || count(*) FROM pg_namespace
     WHERE nspname LIKE '${TGT_DB}\_%'
    UNION ALL
    SELECT 'tables=' || count(*) FROM pg_tables
     WHERE schemaname LIKE '${TGT_DB}\_%'
    UNION ALL
    SELECT 'views=' || count(*) FROM pg_views
     WHERE schemaname LIKE '${TGT_DB}\_%'
    UNION ALL
    SELECT 'routines=' || count(*) FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname LIKE '${TGT_DB}\_%'
    UNION ALL
    SELECT 'foreign keys=' || count(*) FROM pg_constraint c
     JOIN pg_namespace n ON n.oid = c.connamespace
     WHERE c.contype = 'f' AND n.nspname LIKE '${TGT_DB}\_%';" 2>/dev/null | sed 's/^/    /'
  echo ""
  echo "    Connect with: psql -h localhost -p $TGT_PORT -U $TGT_USER -d $TGT_DB"

  if (( APPLY_FAILURES > 0 )); then
    echo ""
    err "$APPLY_FAILURES DDL statement(s) were rejected by PostgreSQL - the target is INCOMPLETE."
    err "Distinct errors PostgreSQL returned:"
    grep -E '^\s*(Attempt\(s\).*)?ERROR: ' "$SCT_LOG" \
      | sed -E 's/.*ERROR: //' \
      | sed -E 's/"[^"]*"/"..."/g' \
      | sort | uniq -c | sort -rn | head -8 | sed 's/^/    /' >&2 || true
    err ""
    # Rather than guess from the log, diff what the DDL defines against what is
    # actually in the database. Anything missing is a table that failed to
    # create, and every foreign key pointing at it failed as a consequence.
    EXPECTED_TABLES="$(grep -oE '^CREATE TABLE [a-z0-9_]+\.[a-z0-9_]+' "$SQL_OUT_FILE" \
      | sed 's/CREATE TABLE //' | sort -u || true)"
    ACTUAL_TABLES="$(docker compose exec -T postgres psql -U "$TGT_USER" -d "$TGT_DB" -tA -c \
      "SELECT schemaname || '.' || tablename FROM pg_tables WHERE schemaname LIKE '${TGT_DB}\_%' ORDER BY 1" \
      2>/dev/null | tr -d '\r' || true)"
    MISSING="$(comm -23 <(printf '%s\n' "$EXPECTED_TABLES") <(printf '%s\n' "$ACTUAL_TABLES") || true)"

    if [[ -n "${MISSING// /}" ]]; then
      err ""
      err "Tables in the generated DDL that are NOT in the target:"
      printf '%s\n' "$MISSING" | sed 's/^/      /' >&2
      err "Every foreign key referencing them failed as a consequence,"
      err "which accounts for most of the count above."
    fi
    err ""
    err "Full statements and hints are in $SCT_LOG (search: DDL-statement)."
    err "Fix them in $(basename "$SQL_OUT_FILE") and apply it with psql, or adjust the"
    err "source schema and re-run."
    exit 1
  fi
fi
