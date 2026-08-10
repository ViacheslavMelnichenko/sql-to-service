#!/usr/bin/env bash
# Gate tool — task 3.3. The differential: does the generated service, reading from
# Mongo, produce output that matches — value-by-value, after canonicalisation — the
# golden captured from the ORIGINAL T-SQL reading from SQL Server — for every case?
# This is the gate with teeth
# (ADR-0001). It is value-based: both sides pass through corpus/canonicalise.py
# --ordered (Website.SearchForCustomers has an ORDER BY, so row order is part of
# the output) before comparison, so representation never masks a real difference.
#
# NON-CIRCULARITY: the golden was produced with no model in the room, and Mongo is
# seeded mechanically from the SAME relational.sql the golden was captured from
# (seed-mongo.sh → ADR-0003). Neither side is fitted to the other.
#
# Three things this script gets deliberately right:
#   * It SEEDS Mongo first (seed-mongo.sh), so the gate never trusts ambient DB
#     state — a stale collection can't turn a red into a green.
#   * It BUILDS ONCE then runs the COMPILED BINARY (bin/…/SearchForCustomers.dll),
#     never `dotnet run`. `dotnet run` prints NuGet NU1902/NU1903 advisories to
#     stdout ahead of the JSON, which would corrupt the parse. The binary's stdout
#     is clean JSON.
#   * Params come from the SAME case file the golden was captured from
#     (corpus/cases/Website.SearchForCustomers.json), so case↔golden can't drift.
#
#   bash gates/differential.sh          # seed + build + diff all cases
#   NO_SEED=1 bash gates/differential.sh  # skip seeding (Mongo already current)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROC="Website.SearchForCustomers"
CASES="corpus/cases/${PROC}.json"
GOLDEN_DIR="corpus/golden"
PROJ="generated/SearchForCustomers.csproj"
MONGO_URI="${MONGO_URI:-mongodb://localhost:37017/wwi}"
PY="${PYTHON:-py}"

log() { printf '\033[1;34m[differential]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[differential] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[1;32m[differential] PASS:\033[0m %s\n' "$*"; }

[ -f "$CASES" ] || die "case file not found: $CASES"
command -v "$PY" >/dev/null 2>&1 || die "the '$PY' launcher is required (canonicalise.py)"

# 1. Seed Mongo from relational.sql so the differential reads the real seed, not
#    ambient state. Skippable (NO_SEED=1) when a caller has just seeded — the
#    mutation check reuses this script and reseeds once for the whole run.
if [ "${NO_SEED:-0}" != "1" ]; then
  log "seeding Mongo from relational.sql"
  bash corpus/seed/seed-mongo.sh >/dev/null 2>&1 \
    || die "seed-mongo.sh failed (engines up? pymongo installed?)"
fi

# 2. Build ONCE (Release) and locate the compiled binary. Never `dotnet run`.
log "building service (Release)"
dotnet build -c Release --nologo "$PROJ" >/dev/null \
  || die "service does not build"
BIN="$(find generated/bin/Release -name 'SearchForCustomers.dll' | head -1)"
[ -n "$BIN" ] || die "built binary not found under generated/bin/Release"

# 3. Extract (case, SearchText, MaximumRowsToReturn) from the case file as
#    tab-separated lines. Done in Python (the '$PY' we already require) so the
#    param mapping matches the type contract in the case file exactly.
mapfile -t ROWS < <("$PY" - "$CASES" <<'PYEOF'
import json, sys
spec = json.load(open(sys.argv[1], encoding="utf-8"))
for case in spec["cases"]:
    p = {x["name"]: x["value"] for x in case.get("params", [])}
    # The runner's argv: <SearchText> <MaximumRowsToReturn>. Tab-separated so a
    # search text with spaces (there are none here, but be safe) survives.
    print(f"{case['name']}\t{p['SearchText']}\t{p['MaximumRowsToReturn']}")
PYEOF
)
[ "${#ROWS[@]}" -gt 0 ] || die "no cases parsed from $CASES"

fail=0
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r name search maxrows <<<"$row"
  golden="${GOLDEN_DIR}/${PROC}__${name}.json"
  [ -f "$golden" ] || { printf '  %-24s MISSING golden: %s\n' "$name" "$golden" >&2; fail=1; continue; }

  got="$(dotnet "$BIN" "$search" "$maxrows" "$MONGO_URI" | "$PY" corpus/canonicalise.py --ordered)"
  want="$("$PY" corpus/canonicalise.py --ordered "$golden")"

  if [ "$got" = "$want" ]; then
    printf '  \033[1;32m✓\033[0m %-24s identical after canonicalise\n' "$name"
  else
    printf '  \033[1;31m✗\033[0m %-24s DIFFERS:\n' "$name" >&2
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
    fail=1
  fi
done

[ "$fail" = "0" ] || die "one or more cases differ from golden"
ok "all ${#ROWS[@]} cases identical to golden (value-based, canonicalised)"
