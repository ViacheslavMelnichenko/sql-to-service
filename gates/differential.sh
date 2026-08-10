#!/usr/bin/env bash
# Gate tool — task 3.3. The differential: does the generated service, reading from
# Mongo, produce output that matches — value-by-value, after canonicalisation — the
# golden captured from the ORIGINAL T-SQL reading from SQL Server — for every case?
# This is the gate with teeth (ADR-0001). It is value-based: both sides pass through
# corpus/canonicalise.py before comparison (with --ordered when the proc has an
# ORDER BY, so row order is part of the output), so representation never masks a real
# difference.
#
# NON-CIRCULARITY: the golden was produced with no model in the room, and Mongo is
# seeded mechanically from the SAME relational.sql the golden was captured from
# (seed-mongo.sh → ADR-0003). Neither side is fitted to the other.
#
# PROC-AGNOSTIC (B.1). This script knows nothing about any one procedure. It takes a
# PROC name and drives everything from committed data:
#   * corpus/cases/<PROC>.json  — the cases, their params, and `ordered`
#   * generated/runners.json     — which csproj to build and which assembly to run
#   * corpus/golden/<PROC>__<case>.json — the oracle per case
# The runner takes the case's `params` as a single JSON value on argv (the uniform
# runner contract), so this script passes params through verbatim — no per-proc
# knowledge of argument names, order, or types.
#
# Three things this script gets deliberately right:
#   * It SEEDS Mongo first (seed-mongo.sh), so the gate never trusts ambient DB
#     state — a stale collection can't turn a red into a green.
#   * It BUILDS ONCE then runs the COMPILED BINARY (bin/…/<assembly>.dll), never
#     `dotnet run`. `dotnet run` prints NuGet NU1902/NU1903 advisories to stdout
#     ahead of the JSON, which would corrupt the parse. The binary's stdout is clean.
#   * Params come from the SAME case file the golden was captured from, so
#     case↔golden can't drift.
#
#   bash gates/differential.sh                                  # showcase proc (default)
#   bash gates/differential.sh Integration.GetStockHoldingUpdates
#   NO_SEED=1 bash gates/differential.sh <PROC>                  # skip seeding
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROC="${1:-Website.SearchForCustomers}"
CASES="corpus/cases/${PROC}.json"
GOLDEN_DIR="corpus/golden"
MANIFEST="generated/runners.json"
MONGO_URI="${MONGO_URI:-mongodb://localhost:37017/wwi}"
PY="${PYTHON:-py}"

log() { printf '\033[1;34m[differential]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[differential] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[1;32m[differential] PASS:\033[0m %s\n' "$*"; }

[ -f "$CASES" ]    || die "case file not found: $CASES"
[ -f "$MANIFEST" ] || die "runner manifest not found: $MANIFEST"
command -v "$PY" >/dev/null 2>&1 || die "the '$PY' launcher is required (canonicalise.py)"

# Resolve (csproj, assembly) for this PROC from the manifest. tr -d '\r': the `py`
# launcher emits CRLF on Windows; strip the CR or the assembly name carries a
# trailing \r and no .dll matches.
read -r PROJ ASSEMBLY < <("$PY" - "$MANIFEST" "$PROC" <<'PYEOF' | tr -d '\r'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
r = m.get(sys.argv[2])
if not r:
    sys.stderr.write(f"proc {sys.argv[2]!r} not in manifest\n"); sys.exit(3)
print(r["csproj"], r["assembly"])
PYEOF
) || die "proc '$PROC' not found in $MANIFEST (add its csproj/assembly there)"

# Is row order part of this proc's output? (ORDER BY → yes.) Drives --ordered.
ORDERED_FLAG="$("$PY" - "$CASES" <<'PYEOF' | tr -d '\r'
import json, sys
spec = json.load(open(sys.argv[1], encoding="utf-8"))
print("--ordered" if spec.get("ordered") else "")
PYEOF
)"

# 1. Seed Mongo from relational.sql so the differential reads the real seed, not
#    ambient state. Skippable (NO_SEED=1) when a caller has just seeded — the
#    mutation check reuses this script and reseeds once for the whole run.
if [ "${NO_SEED:-0}" != "1" ]; then
  log "seeding Mongo from relational.sql"
  bash corpus/seed/seed-mongo.sh >/dev/null 2>&1 \
    || die "seed-mongo.sh failed (engines up? pymongo installed?)"

  # SEED-IDENTITY ASSERTION (B.6). seed-mongo.sh re-exports relational.json from a
  # freshly-reseeded SQL Server; the golden was captured from an EARLIER export.
  # The whole non-circularity story rests on both stores descending from ONE seed —
  # but if this container's SQL Server exports even subtly differently (collation,
  # geography WKT, a float/decimal edge), the Mongo side drifts from golden silently
  # and every case could still "match" a drifted oracle. So diff the just-regenerated
  # export against the committed copy the golden derived from, and fail loudly on any
  # drift. Compare line-ending-normalised (the `py` launcher writes CRLF on Windows):
  # it is CONTENT identity we assert, not byte identity across OSes.
  REL_JSON="corpus/seed/relational.json"
  if git rev-parse --show-toplevel >/dev/null 2>&1 && git ls-files --error-unmatch "$REL_JSON" >/dev/null 2>&1; then
    if ! diff <(git show "HEAD:$REL_JSON" | tr -d '\r') <(tr -d '\r' < "$REL_JSON") >/dev/null 2>&1; then
      printf '\033[1;31m[differential] FAIL:\033[0m seed drift — the freshly exported %s\n' "$REL_JSON" >&2
      printf '  differs from the committed copy the golden was captured from (ADR-0001/0003).\n' >&2
      printf '  This container'\''s SQL Server produces a different export; the golden oracle no\n' >&2
      printf '  longer describes the seed Mongo is loaded from. Do NOT trust a green below.\n' >&2
      git --no-pager diff --no-index <(git show "HEAD:$REL_JSON" | tr -d '\r') <(tr -d '\r' < "$REL_JSON") 2>/dev/null | head -40 >&2 || true
      die "seed-identity assertion failed (B.6): relational.json drifted from committed"
    fi
    log "seed-identity OK — regenerated relational.json matches the committed seed"
  fi
fi

# 2. Build ONCE (Release) and locate the compiled binary. Never `dotnet run`.
log "building service (Release): $PROJ"
dotnet build -c Release --nologo "$PROJ" >/dev/null \
  || die "service does not build: $PROJ"
BIN="$(find generated/bin/Release -name "${ASSEMBLY}.dll" | head -1)"
[ -n "$BIN" ] || die "built binary not found: ${ASSEMBLY}.dll under generated/bin/Release"

# 3. Extract (case, paramsJson) from the case file as tab-separated lines. paramsJson
#    is the case's `params` array serialised compact — handed to the runner verbatim
#    (the uniform contract). Base64 the JSON so tabs/quotes/spaces in it can never
#    break the tab-separated framing.
mapfile -t ROWS < <("$PY" - "$CASES" <<'PYEOF' | tr -d '\r'
import json, sys, base64
spec = json.load(open(sys.argv[1], encoding="utf-8"))
for case in spec["cases"]:
    params = case.get("params", [])
    blob = base64.b64encode(json.dumps(params).encode("utf-8")).decode("ascii")
    print(f"{case['name']}\t{blob}")
PYEOF
)
[ "${#ROWS[@]}" -gt 0 ] || die "no cases parsed from $CASES"

fail=0
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r name blob <<<"$row"
  params_json="$(printf '%s' "$blob" | "$PY" -c 'import sys,base64; sys.stdout.write(base64.b64decode(sys.stdin.read()).decode("utf-8"))')"
  golden="${GOLDEN_DIR}/${PROC}__${name}.json"
  [ -f "$golden" ] || { printf '  %-24s MISSING golden: %s\n' "$name" "$golden" >&2; fail=1; continue; }

  got="$(dotnet "$BIN" "$params_json" "$MONGO_URI" | "$PY" corpus/canonicalise.py $ORDERED_FLAG)"
  want="$("$PY" corpus/canonicalise.py $ORDERED_FLAG "$golden")"

  if [ "$got" = "$want" ]; then
    printf '  \033[1;32m✓\033[0m %-24s identical after canonicalise\n' "$name"
  else
    printf '  \033[1;31m✗\033[0m %-24s DIFFERS:\n' "$name" >&2
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
    fail=1
  fi
done

[ "$fail" = "0" ] || die "one or more cases differ from golden ($PROC)"
ok "all ${#ROWS[@]} cases identical to golden — $PROC (value-based, canonicalised)"
