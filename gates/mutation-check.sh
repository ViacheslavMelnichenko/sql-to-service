#!/usr/bin/env bash
# Gate-VALIDATION — task 3.9, MANDATORY, blocks Phase-3 exit (ADR-0006). A
# differential gate that has never been shown to FAIL on a wrong conversion is an
# untested gate; its green is worth nothing. This script proves the gate has teeth:
# it takes a known-correct service, injects a catalogue of known bugs one at a time,
# and asserts the differential (gates/differential.sh) catches EVERY one. A single
# uncaught mutant fails this check — and, per ADR-0006, points at the cause: either
# the comparison is too loose, or the seed has a branch hole (ADR-0002) that makes
# the mutant produce identical golden.
#
# PROC-AGNOSTIC (B.1). It takes a PROC name, reads the service source to mutate from
# generated/runners.json, and applies that proc's own mutation catalogue (each proc
# exercises the ADR-0006 bug classes its shape actually has). With no argument it runs
# EVERY proc in the manifest, so the whole corpus's gate-teeth are validated in one
# pass.
#
# The ADR-0006 bug classes, and where each proc exercises them:
#   Website.SearchForCustomers        (FOR JSON join + filter + pagination)
#     drop-where · break-order · shift-pagination · drop-join · type-coercion
#   Integration.GetStockHoldingUpdates (tabular, decimal-bearing, zero-param)
#     precision-loss (decimal→double) · break-order · type-coercion
#   The precision-loss mutant is the one the showcase proc CANNOT exercise (it returns
#   no decimal column); this proc is why it exists in the corpus (ADR-0006).
#   Integration.GetTransactionUpdates (UNION ALL of two windowed arms, LEFT JOIN)
#     drop-window · drop-arm · precision-loss · type-coercion
#   NOT break-join/coalesce: this seed has no row where the invoice's CustomerID differs
#   from the transaction's, so that mutant would be a no-op (ADR-0002 branch hole) — a
#   gate with no teeth is exactly what this check forbids, so it is left out, not faked.
#
# Mechanism: back up the service source, apply ONE single-line mutation, run the
# differential (Mongo seeded once up front, then NO_SEED=1 so each mutant reuses it),
# and require a NON-ZERO exit (the gate caught the bug). Restore between mutants; a
# trap restores on any exit so a crash never leaves the tree mutated.
#
#   bash gates/mutation-check.sh                                   # every proc
#   bash gates/mutation-check.sh Integration.GetStockHoldingUpdates
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MANIFEST="generated/runners.json"
PY="${PYTHON:-py}"

log() { printf '\033[1;34m[mutation]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[mutation] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[1;32m[mutation] PASS:\033[0m %s\n' "$*"; }

[ -f "$MANIFEST" ] || die "runner manifest not found: $MANIFEST"
command -v perl >/dev/null 2>&1 || die "perl is required for the in-place mutations"
command -v "$PY" >/dev/null 2>&1 || die "the '$PY' launcher is required (reads $MANIFEST)"

# --- mutation state (set per proc) -------------------------------------------------
SRC=""
BACKUP=""
SEEDED=0
CURPROC=""

restore() { [ -n "$BACKUP" ] && [ -n "$SRC" ] && cp "$BACKUP" "$SRC"; }
cleanup() { restore; [ -n "$BACKUP" ] && rm -f "$BACKUP"; }
trap cleanup EXIT

# perl -0777 literal find/replace via \Q...\E; die if the anchor is absent (a refactor
# moved it) so a mutation can never silently become a no-op — a no-op mutation would
# "pass unnoticed" and falsely credit the gate.
mutate() {
  local find="$1" repl="$2"
  restore
  FIND="$find" REPL="$repl" perl -0777 -i -pe '
    my ($f,$r)=($ENV{FIND},$ENV{REPL});
    my $n = s/\Q$f\E/$r/g;
    die "anchor not found: $f\n" unless $n > 0;
  ' "$SRC" || die "mutation anchor not found (source refactored?): $find"
}

# Run the differential for CURPROC against the CURRENT (mutated) source. Expect
# FAILURE. Seed only on the first call across the whole run (SEEDED), reuse after.
expect_caught() {
  local label="$1" out rc
  if [ "$SEEDED" = "0" ]; then
    rc=0; out="$(bash gates/differential.sh "$CURPROC" 2>&1)" || rc=$?
    SEEDED=1
  else
    rc=0; out="$(NO_SEED=1 bash gates/differential.sh "$CURPROC" 2>&1)" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    printf '  \033[1;32m✓\033[0m %-18s caught (differential red)\n' "$label"
  else
    printf '  \033[1;31m✗\033[0m %-18s UNCAUGHT — gate stayed green on a known bug\n' "$label" >&2
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    die "uncaught mutant '$label': the comparison is too loose OR the seed has a branch hole (ADR-0002/0006)"
  fi
}

baseline() {
  # Pristine source MUST pass, or the whole check is meaningless (we'd be "catching"
  # bugs that were never fixed). The first proc's baseline does the one seed.
  log "baseline ($CURPROC): pristine service must PASS the differential"
  restore
  local rc=0
  if [ "$SEEDED" = "0" ]; then
    bash gates/differential.sh "$CURPROC" >/dev/null 2>&1 || rc=$?
    [ "$rc" = "0" ] && SEEDED=1
  else
    NO_SEED=1 bash gates/differential.sh "$CURPROC" >/dev/null 2>&1 || rc=$?
  fi
  [ "$rc" = "0" ] || die "baseline FAILED ($CURPROC) — cannot validate a gate against a service that is already red"
  ok "baseline green ($CURPROC) — the gate agrees the unmutated service is correct"
}

# Per-proc catalogues. Each sets SRC/BACKUP for its proc, runs baseline, then a
# sequence of mutate+expect_caught. Keeping them as functions (not data) lets each
# anchor be the exact source line, which is what makes a no-op mutation impossible.

mutants_SearchForCustomers() {
  log "injecting 5 mutations; each must turn the differential red"
  # 1. drop-where — neuter the LIKE filter so every city-joined customer is returned.
  mutate 'if (!LikeContains(haystack, searchText))' \
         'if (false && !LikeContains(haystack, searchText))'
  expect_caught "drop-where"
  # 2. break-order — ascending CustomerName → descending (right rows, wrong order).
  mutate '.OrderBy(r => r.SortKey, StringComparer.Ordinal)' \
         '.OrderByDescending(r => r.SortKey, StringComparer.Ordinal)'
  expect_caught "break-order"
  # 3. shift-pagination — TOP(n) → TOP(n+1), an off-by-one page window.
  mutate '.Take(Math.Max(0, maximumRowsToReturn))' \
         '.Take(Math.Max(0, maximumRowsToReturn + 1))'
  expect_caught "shift-pagination"
  # 4. drop-join — never resolve the LEFT JOIN to People (person stays null).
  mutate 'if (contactId is not null)' \
         'if (false && contactId is not null)'
  expect_caught "drop-join"
  # 5. type-coercion — emit CustomerID as a string, not an int.
  mutate 'private static int CustomerId(BsonDocument customer) => customer["_id"].ToInt32();' \
         'private static string CustomerId(BsonDocument customer) => customer["_id"].ToInt32().ToString();'
  expect_caught "type-coercion"
}

mutants_GetStockHoldingUpdates() {
  log "injecting 3 mutations; each must turn the differential red"
  # 1. precision-loss — emit LastCostPrice THROUGH a double instead of the exact
  #    fixed-scale-4 string. THE mutant the whole artifact exists to catch (ADR-0006).
  #    SUBTLE, and worth stating because it bit a refactor once: the service emits a
  #    scale-4 STRING ("8.0000"), and canonicalise.py re-pads any dotted numeric string
  #    to scale 4 on BOTH sides. So a mutant that only reads via double but STILL emits
  #    via ToString("F4") is a no-op — F4 re-imposes the scale the double lost. To bite,
  #    the mutant must also bypass the F4 re-pad: ((double)value).ToString() serialises
  #    8.00 → 8.0d → "8" (no dot), which canonicalise leaves as bare "8" (it only
  #    re-pads strings containing "." or "e"), and "8" != golden's "8.0000".
  #    BRANCH-HOLE NOTE (ADR-0002): the StockItemID=2 row (LastCostPrice 8.00) is
  #    LOAD-BEARING. The 12.50 row alone would NOT catch it — 12.5 via double is "12.5",
  #    which HAS a dot and re-pads to "12.5000", matching golden. It is the whole-number
  #    .00 value whose scale double drops to a dotless string. Do not drop that row.
  mutate 'return value.ToString("F4", CultureInfo.InvariantCulture);' \
         'return ((double)value).ToString(CultureInfo.InvariantCulture);'
  expect_caught "precision-loss"
  # 2. break-order — ascending StockItemID → descending (right rows, wrong order).
  mutate '.OrderBy(StockItemId)' \
         '.OrderByDescending(StockItemId)'
  expect_caught "break-order"
  # 3. type-coercion — emit WWI Stock Item ID as a string, not an int.
  mutate 'private static int StockItemId(BsonDocument h) => h["_id"].ToInt32();' \
         'private static string StockItemId(BsonDocument h) => h["_id"].ToInt32().ToString();'
  expect_caught "type-coercion"
}

mutants_GetTransactionUpdates() {
  log "injecting 4 mutations; each must turn the differential red"
  # This proc's shape is a UNION ALL of two windowed arms with a LEFT JOIN. Its bug
  # classes are the window predicate, the arm union, decimal emission, and id typing.
  # NOT included, deliberately (ADR-0002): a COALESCE/break-join mutant has NO teeth on
  # THIS seed — every joined row has i.CustomerID == ct.CustomerID (jan: WWI Customer ID
  # == WWI Bill To Customer ID == 1), so swapping the coalesce order or dropping the
  # join changes no output. Adding that mutant would need a seed row where the invoice's
  # CustomerID differs from the transaction's; until the seed carries it, claiming to
  # test the join here would be a gate with no teeth, which is the thing this check bans.
  # 1. drop-window — neuter the half-open window so EVERY transaction is returned
  #    regardless of cutoff. The empty-window case (2019) then yields rows instead of
  #    [], and jan pulls in Feb's CT 2 — the differential goes red.
  mutate 'return when.Value > lastCutoff && when.Value <= newCutoff;' \
         'return true;'
  expect_caught "drop-window"
  # 2. drop-arm — never emit the supplier arm. The jan case loses ST 1 (its only
  #    supplier row, SupplierInvoiceNumber "SI-001"), so the row bag no longer matches.
  mutate 'rows.AddRange(SupplierArm(lastCutoff, newCutoff));' \
         '// rows.AddRange(SupplierArm(lastCutoff, newCutoff));'
  expect_caught "drop-arm"
  # 3. precision-loss — same double-bypass-F4 mutant as the stock proc, on the money
  #    columns. 250.00/0.00 via double serialise dotless ("250"/"0"), which canonicalise
  #    leaves un-padded, so they differ from golden's "250.0000"/"0.0000". (See the long
  #    note on the stock proc for why bypassing F4 is what gives this mutant teeth.)
  mutate 'return value.ToString("F4", CultureInfo.InvariantCulture);' \
         'return ((double)value).ToString(CultureInfo.InvariantCulture);'
  expect_caught "precision-loss"
  # 4. type-coercion — emit the transaction id as a string, not an int. Both arms use
  #    Id(...) for their *-Transaction ID column, so "1" vs 1 breaks the comparison.
  mutate 'private static int Id(BsonDocument doc) => doc["_id"].ToInt32();' \
         'private static string Id(BsonDocument doc) => doc["_id"].ToInt32().ToString();'
  expect_caught "type-coercion"
}

# Map a PROC to its catalogue function (the assembly name is the stable, dot-free key).
run_proc() {
  CURPROC="$1"
  SRC="$("$PY" - "$MANIFEST" "$CURPROC" <<'PYEOF' | tr -d '\r'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
r = m.get(sys.argv[2])
if not r:
    sys.stderr.write(f"proc {sys.argv[2]!r} not in manifest\n"); sys.exit(3)
print(r["service"])
PYEOF
)" || die "proc '$CURPROC' not in manifest"
  [ -f "$SRC" ] || die "service source not found for $CURPROC: $SRC"

  BACKUP="$(mktemp)"
  cp "$SRC" "$BACKUP"

  baseline
  case "$CURPROC" in
    Website.SearchForCustomers)         mutants_SearchForCustomers ;;
    Integration.GetStockHoldingUpdates) mutants_GetStockHoldingUpdates ;;
    Integration.GetTransactionUpdates)  mutants_GetTransactionUpdates ;;
    *) die "no mutation catalogue defined for '$CURPROC' — add one (ADR-0006: every converted proc needs proven teeth)" ;;
  esac

  restore
  rm -f "$BACKUP"; BACKUP=""
  ok "$CURPROC: all mutants caught — the differential has teeth (ADR-0006)"
}

# Which procs? One if named, else every proc in the manifest.
if [ "$#" -ge 1 ]; then
  PROCS=("$1")
else
  mapfile -t PROCS < <("$PY" - "$MANIFEST" <<'PYEOF' | tr -d '\r'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
for k in m:
    if k != "//": print(k)
PYEOF
)
fi
[ "${#PROCS[@]}" -gt 0 ] || die "no procs to mutation-check"

for p in "${PROCS[@]}"; do
  run_proc "$p"
done

ok "all procs' mutants caught — every gate in the corpus has proven teeth (ADR-0006)"
