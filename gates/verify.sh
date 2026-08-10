#!/usr/bin/env bash
# Gate tool — task 3.4. verify = build + unit + differential, with NO model calls.
# This is the reproducible verdict a reviewer (or CI) runs to confirm the converted
# service is correct without paying for, or trusting, an agent: it compiles, its
# agent-written tests pass, and its output is byte-identical to the golden captured
# from the original T-SQL. Everything it needs is committed (code, tests, golden,
# seed); the only runtime dependency is the two containers on :11433 / :37017.
#
# Order is fail-fast and cheapest-first: a non-compiling service can't be tested,
# and failing unit tests usually explain a differential failure, so surface those
# first. The differential seeds Mongo itself (seed-mongo.sh).
#
#   bash gates/verify.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '\033[1;35m[verify]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[verify] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[1;32m[verify] PASS:\033[0m %s\n' "$*"; }

log "1/3 build"
bash gates/build.sh        || die "build gate failed"

log "2/3 unit tests"
bash gates/unit.sh         || die "unit gate failed"

log "3/3 differential vs golden"
bash gates/differential.sh || die "differential gate failed"

ok "build + unit + differential all green — verdict reproduced with no model calls"
