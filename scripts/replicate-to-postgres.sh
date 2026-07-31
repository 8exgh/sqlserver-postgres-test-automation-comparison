#!/usr/bin/env bash
#
# Copies the sample data from SQL Server into PostgreSQL, so the parity suite
# compares the two engines over identical inputs.
#
# SQL Server is the source of truth: db/sqlserver/021_seed_sample_data.sql
# authors the data and there is no PostgreSQL seed to drift from it. Reference
# data (ref.*) is NOT copied -- each side seeds it from its own
# 020_seed_reference_data.sql, so comparing it stays a real test.
#
#   scripts/replicate-to-postgres.sh
#
# Both containers must be running with their schemas applied.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

exec dotnet run --project tests/DbParity.Replicate/DbParity.Replicate.csproj \
                --configuration Release \
                --verbosity quiet \
                --
