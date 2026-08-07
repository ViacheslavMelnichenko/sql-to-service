#!/usr/bin/env bash
# Extract the selected procedures VERBATIM from the restored database into
# corpus/procs/<Schema>.<Name>.sql — one file each. These committed files are the
# source of truth the analyst subagent reads; capturing them from the live DB (not
# retyping) guarantees they are byte-for-byte what golden was captured from.
#
# The set is the 14 marked IN in corpus/SELECTION.md. Editing that list here and
# there must stay in sync — SELECTION.md is the human record, this array is the
# machine one; the count check at the end guards against drift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
[ -f .env ] && set -a && . ./.env && set +a
: "${MSSQL_SA_PASSWORD:?set MSSQL_SA_PASSWORD in .env}"

SVC="mssql"
DB="WideWorldImporters"
OUT="$ROOT/corpus/procs"
mkdir -p "$OUT"

# The corpus (SELECTION.md §Enumeration, Verdict = IN). Schema.Name.
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
  "Integration.GetCityUpdates"
  "Integration.GetCustomerUpdates"
  "Integration.GetSupplierUpdates"
)

log() { printf '\033[1;34m[extract]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[extract] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# -y0 = unlimited column width (proc bodies exceed the default 256). No -h with -y0.
dump() {
  MSYS_NO_PATHCONV=1 docker compose exec -T "$SVC" /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -No -b -y0 "$@"
}

count=0
for full in "${PROCS[@]}"; do
  file="$OUT/${full}.sql"
  # OBJECT_DEFINITION returns the exact stored text. Strip only sqlcmd's chrome
  # (the trailing "rows affected" line and any blank leader), never the body.
  dump -Q "SET NOCOUNT ON; USE [$DB]; SELECT OBJECT_DEFINITION(OBJECT_ID(N'$full'));" \
    | grep -vE '^\(1 rows affected\)$|^Changed database context' \
    | sed '/./,$!d' \
    > "$file"
  # Sanity: the file must start with CREATE PROCEDURE for that name.
  head -5 "$file" | grep -qi "CREATE PROCEDURE" \
    || die "extract of $full does not look like a procedure body — see $file"
  bytes=$(wc -c < "$file")
  log "wrote ${full}.sql ($bytes bytes)"
  count=$((count + 1))
done

[ "$count" -eq 14 ] || die "expected 14 procedures, wrote $count — sync PROCS with SELECTION.md"
log "extracted $count procedures verbatim ✓"
