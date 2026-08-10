#!/usr/bin/env bash
# Capture golden output for the whole corpus — the ADR-0001 oracle, produced
# with NO model in the room. This is task 1.6.
#
# It is the entry point the seed header points at. Three steps, in order:
#   1. (Re)apply corpus/seed/relational.sql   — the branch-covering seed (ADR-0007).
#   2. Load all 14 procedures VERBATIM from corpus/procs/*.sql into the
#      seed database — the SAME committed files the analyst subagent reads, so
#      golden is captured from byte-for-byte the text under conversion.
#   3. Run corpus/capture-golden.py, which executes every case in corpus/cases/*.json
#      and writes one canonical golden file per case to corpus/golden/.
#
# Steps 1 and 2 are re-run every time so a capture is reproducible from a clean
# container — golden must never depend on ambient DB state. The Python driver does
# the per-case work (both output shapes, canonicalisation); see its header.
#
# Determinism (task 1.9): the seed is all fixed literals and neither the procs nor
# the driver add wall-clock/random values, so re-running this yields byte-identical
# golden. gates/verify-stable.sh asserts exactly that.
#
# Usage:
#   bash corpus/capture-golden.sh [OUTPUT_DIR]
#
# OUTPUT_DIR defaults to corpus/golden (the committed oracle). gates/verify-stable.sh
# passes a temp dir so a stability re-capture never disturbs the committed tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT_DIR="${1:-corpus/golden}"
# shellcheck disable=SC1091
[ -f .env ] && set -a && . ./.env && set +a
: "${MSSQL_SA_PASSWORD:?set MSSQL_SA_PASSWORD in .env}"

SVC="mssql"
DB="WwiSeed"

# All 14 procedures (ADR-0007). The last three are the tranche-2 temporal procs
# (system-versioned tables + *_Archive history + a geography Location column); the
# merged relational.sql seeds what they need, and capture-golden.py reads geography
# as WKT so it survives FOR JSON.
PROCS=(
  "Website.SearchForCustomers"
  "Website.SearchForSuppliers"
  "Website.SearchForStockItems"
  "Website.SearchForStockItemsByTags"
  "Website.SearchForPeople"
  "Integration.GetOrderUpdates"
  "Integration.GetSaleUpdates"
  "Integration.GetPurchaseUpdates"
  "Integration.GetMovementUpdates"
  "Integration.GetTransactionUpdates"
  "Integration.GetStockHoldingUpdates"
  "Integration.GetCustomerUpdates"
  "Integration.GetSupplierUpdates"
  "Integration.GetCityUpdates"
)

log() { printf '\033[1;34m[capture]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[capture] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# sqlcmd in the container. MSYS_NO_PATHCONV=1 stops Git-Bash rewriting the exec
# path (/opt/...) into a Windows path; -b makes it exit non-zero on a SQL error.
run_sql() {
  MSYS_NO_PATHCONV=1 docker compose exec -T "$SVC" /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -No -b "$@"
}

# 1. Reseed. relational.sql drops+recreates WwiSeed, so this is idempotent.
log "applying relational seed → $DB"
run_sql -i /corpus/seed/relational.sql >/dev/null \
  || die "relational.sql failed — the seed does not apply cleanly"

# 2. Load all 14 procs verbatim. DROP IF EXISTS first so a re-run is clean; the
#    proc files live under /corpus (the compose read-only mount of ./corpus).
for full in "${PROCS[@]}"; do
  [ -f "corpus/procs/${full}.sql" ] || die "missing corpus/procs/${full}.sql"
  run_sql -d "$DB" -Q "DROP PROCEDURE IF EXISTS ${full};" >/dev/null
  # A column the proc reads that the seed omits fails HERE, loudly (ADR-0007).
  run_sql -d "$DB" -i "/corpus/procs/${full}.sql" >/dev/null \
    || die "loading ${full} failed — proc references something the seed lacks?"
done
log "loaded ${#PROCS[@]} procedures verbatim into $DB"

# 3. Capture. The Python driver runs on the HOST (py launcher): some Docker Hub
#    images are AV-blocked here, and the driver only needs stdlib + docker CLI.
log "running per-case capture → $OUT_DIR/"
PY="${PYTHON:-py}"
"$PY" corpus/capture-golden.py --db "$DB" \
  --cases corpus/cases --out "$OUT_DIR" \
  || die "capture-golden.py failed"

count=$(find "$OUT_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
log "captured $count golden files → $OUT_DIR ✓"
