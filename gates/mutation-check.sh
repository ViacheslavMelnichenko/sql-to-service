#!/usr/bin/env bash
# Gate-VALIDATION — task 3.9, MANDATORY, blocks Phase-3 exit (ADR-0006). A
# differential gate that has never been shown to FAIL on a wrong conversion is an
# untested gate; its green is worth nothing. This script proves the gate has teeth:
# it takes the known-correct showcase service, injects a catalogue of known bugs
# one at a time, and asserts the differential (gates/differential.sh) catches EVERY
# one. A single uncaught mutant fails this check — and, per ADR-0006, points at the
# cause: either the comparison is too loose, or the seed has a branch hole (ADR-0002)
# that makes the mutant produce identical golden.
#
# The catalogue, mapped onto Website.SearchForCustomers (the ADR-0006 bug classes):
#   drop-where       drop the WHERE/LIKE filter          → returns too many rows
#   break-order      ORDER BY ascending → descending      → right rows, wrong order
#   shift-pagination TOP(n) → TOP(n+1)                     → off-by-one window
#   drop-join        drop the LEFT JOIN to People          → missing columns / rows
#   type-coercion    emit CustomerID as a string, not int  → wrong value type
#
# HONEST SCOPE NOTE (no silent cap): the ADR-0006 catalogue also names
# `decimal(18,4) → float` precision loss. Website.SearchForCustomers returns NO
# decimal column (names, phone/fax strings, integer ids), so that exact mutant has
# no target here; `type-coercion` above stands in for the wrong-numeric-representation
# class. True decimal-precision-loss is exercised when a money-returning Integration
# .Get*Updates proc is converted — its mutant belongs to that conversion's check,
# not this one. This is stated, not skipped silently.
#
# Mechanism: back up the service source, apply ONE single-line mutation, run the
# differential (Mongo seeded once up front, then NO_SEED=1 so each mutant reuses it),
# and require a NON-ZERO exit (the gate caught the bug). Restore between mutants; a
# trap restores on any exit so a crash never leaves the tree mutated.
#
#   bash gates/mutation-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '\033[1;34m[mutation]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[mutation] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[1;32m[mutation] PASS:\033[0m %s\n' "$*"; }

SRC="generated/SearchForCustomersService.cs"
[ -f "$SRC" ] || die "service source not found: $SRC"
command -v perl >/dev/null 2>&1 || die "perl is required for the in-place mutations"

BACKUP="$(mktemp)"
cp "$SRC" "$BACKUP"
restore() { cp "$BACKUP" "$SRC"; }
trap 'restore; rm -f "$BACKUP"' EXIT

# perl -0777 -pe with literal find/replace via \Q...\E; die if the anchor text is
# absent (a refactor moved it) so a mutation can never silently become a no-op —
# a no-op mutation would "pass unnoticed" and falsely credit the gate.
mutate() {
  local find="$1" repl="$2"
  restore
  FIND="$find" REPL="$repl" perl -0777 -i -pe '
    my ($f,$r)=($ENV{FIND},$ENV{REPL});
    my $n = s/\Q$f\E/$r/g;
    die "anchor not found: $f\n" unless $n > 0;
  ' "$SRC" || die "mutation anchor not found (source refactored?): $find"
}

# Run the differential against the CURRENT (mutated) source. Expect FAILURE.
# Seed only on the first call (SEEDED), reuse the seed after (NO_SEED=1) — the seed
# is constant, only the code changes.
SEEDED=0
expect_caught() {
  local label="$1" out rc
  # `|| rc=$?` keeps `set -e` from killing us on the NON-ZERO exit we are hoping
  # for — a caught mutant makes the differential exit red, which is success here.
  if [ "$SEEDED" = "0" ]; then
    rc=0; out="$(bash gates/differential.sh 2>&1)" || rc=$?
    SEEDED=1
  else
    rc=0; out="$(NO_SEED=1 bash gates/differential.sh 2>&1)" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    printf '  \033[1;32m✓\033[0m %-18s caught (differential red)\n' "$label"
  else
    printf '  \033[1;31m✗\033[0m %-18s UNCAUGHT — gate stayed green on a known bug\n' "$label" >&2
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    die "uncaught mutant '$label': the comparison is too loose OR the seed has a branch hole (ADR-0002/0006)"
  fi
}

# 0. Baseline sanity: pristine source MUST pass, or the whole check is meaningless
#    (we'd be "catching" bugs that were never fixed). This also does the one seed.
log "baseline: pristine service must PASS the differential"
restore
if bash gates/differential.sh >/dev/null 2>&1; then
  SEEDED=1
  ok "baseline green — the gate agrees the unmutated service is correct"
else
  die "baseline FAILED — cannot validate a gate against a service that is already red"
fi

log "injecting 5 mutations; each must turn the differential red"

# 1. drop-where — neuter the LIKE filter so every city-joined customer is returned.
mutate \
  'if (!LikeContains(haystack, searchText))' \
  'if (false && !LikeContains(haystack, searchText))'
expect_caught "drop-where"

# 2. break-order — ascending CustomerName → descending (right rows, wrong order).
mutate \
  '.OrderBy(r => r.SortKey, StringComparer.Ordinal)' \
  '.OrderByDescending(r => r.SortKey, StringComparer.Ordinal)'
expect_caught "break-order"

# 3. shift-pagination — TOP(n) → TOP(n+1), an off-by-one page window.
mutate \
  '.Take(Math.Max(0, maximumRowsToReturn))' \
  '.Take(Math.Max(0, maximumRowsToReturn + 1))'
expect_caught "shift-pagination"

# 4. drop-join — never resolve the LEFT JOIN to People (person stays null): the
#    contact columns vanish and a contact-only match no longer returns its row.
mutate \
  'if (contactId is not null)' \
  'if (false && contactId is not null)'
expect_caught "drop-join"

# 5. type-coercion — emit CustomerID as a string, not an int (wrong numeric repr).
mutate \
  'private static int CustomerId(BsonDocument customer) => customer["_id"].ToInt32();' \
  'private static string CustomerId(BsonDocument customer) => customer["_id"].ToInt32().ToString();'
expect_caught "type-coercion"

restore
ok "all 5 mutants caught — the differential has teeth (ADR-0006)"
