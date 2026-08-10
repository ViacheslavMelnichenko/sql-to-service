#!/usr/bin/env bash
# Gate tool — task 3.4. verify = build + unit + differential, with NO model calls.
# This is the reproducible verdict a reviewer (or CI) runs to confirm the converted
# service is correct without paying for, or trusting, an agent: it compiles, its
# agent-written tests pass, and its output matches — value-by-value, after
# canonicalisation — the golden captured from the original T-SQL. Everything it
# needs is committed (code, tests, golden,
# seed); the only runtime dependency is the two containers on :11433 / :37017.
#
# PROC-AGNOSTIC (B.1). build + unit build/run the WHOLE corpus in one pass each; the
# differential is per-proc, so this loops it over every proc in generated/runners.json.
# Adding a converted proc (a manifest entry + its files) extends this verdict with no
# edit here. The first differential seeds Mongo; the rest reuse it (NO_SEED=1).
#
# Order is fail-fast and cheapest-first: a non-compiling service can't be tested,
# and failing unit tests usually explain a differential failure, so surface those
# first.
#
#   bash gates/verify.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MANIFEST="generated/runners.json"
PY="${PYTHON:-py}"

log() { printf '\033[1;35m[verify]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[verify] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[1;32m[verify] PASS:\033[0m %s\n' "$*"; }

[ -f "$MANIFEST" ] || die "runner manifest not found: $MANIFEST"

log "1/3 build (all procs)"
bash gates/build.sh        || die "build gate failed"

log "2/3 unit tests (all procs)"
bash gates/unit.sh         || die "unit gate failed"

log "3/3 differential vs golden (per proc)"
mapfile -t PROCS < <("$PY" - "$MANIFEST" <<'PYEOF' | tr -d '\r'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
for k in m:
    if k != "//": print(k)
PYEOF
)
[ "${#PROCS[@]}" -gt 0 ] || die "no procs in $MANIFEST"

seeded=0
for p in "${PROCS[@]}"; do
  if [ "$seeded" = "0" ]; then
    bash gates/differential.sh "$p"          || die "differential gate failed: $p"
    seeded=1
  else
    NO_SEED=1 bash gates/differential.sh "$p" || die "differential gate failed: $p"
  fi
done

ok "build + unit + differential all green (${#PROCS[@]} procs) — verdict reproduced with no model calls"
