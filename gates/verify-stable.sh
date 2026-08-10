#!/usr/bin/env bash
# Stability gate — task 1.9. Golden must be IDENTICAL across two independent
# captures, or it is not an oracle: a golden that shifts between runs cannot tell a
# correct conversion from a wrong one, because "correct" would itself be a moving
# target.
#
# What it proves: corpus/capture-golden.sh is deterministic — the seed is all fixed
# literals (ADR-0007), the procedures add no wall-clock/random values, and the
# canonicaliser imposes a total order — so re-running the whole capture yields
# byte-for-byte the same files. This is the concrete form of the Phase-1 exit
# criterion "golden is deterministic across re-captures."
#
# How: capture once into a temp dir, capture again into a second temp dir, and diff
# the two trees. Any difference — a changed byte, an extra or missing file — fails
# the gate loudly. It does NOT touch the committed corpus/golden/ (a gate reports,
# it does not mutate the artifact it judges).
#
#   bash gates/verify-stable.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '\033[1;34m[verify-stable]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[verify-stable] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[1;32m[verify-stable] PASS:\033[0m %s\n' "$*"; }

# capture-golden.sh takes an OUTPUT_DIR argument; pass a temp dir so the committed
# corpus/golden/ tree is never touched (a gate reports, it does not mutate the
# artifact it judges).
cap() {
  local out="$1"
  bash corpus/capture-golden.sh "$out" >/dev/null 2>&1 || die "capture into staging failed"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
A="$TMP/a"; B="$TMP/b"

log "capture #1"
cap "$A"
a_count=$(find "$A" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')

log "capture #2"
cap "$B"
b_count=$(find "$B" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')

[ "$a_count" = "$b_count" ] || die "file count differs between captures: $a_count vs $b_count"
[ "$a_count" -gt 0 ] || die "no golden files captured — nothing to compare"

# Byte-for-byte tree comparison. -r catches added/removed files too, not just
# content drift in shared ones.
if diff -r "$A" "$B" >"$TMP/diff.out" 2>&1; then
  ok "$a_count golden files byte-identical across two captures"
else
  printf '%s\n' "$(cat "$TMP/diff.out")" >&2
  die "golden differs between captures — capture is NOT deterministic (see diff above)"
fi
