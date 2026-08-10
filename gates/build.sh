#!/usr/bin/env bash
# Gate tool — task 3.1. Build the generated service(s). The first gate the pipeline
# runs after the implementer writes code: does it even compile? A conversion that
# does not build cannot be differentially tested, so this fails fast and loud before
# the unit and differential gates are attempted.
#
# PROC-AGNOSTIC (B.1). With no argument it builds EVERY proc in generated/runners.json
# (so `make`/CI/verify.sh cover the whole corpus); given a PROC it builds just that
# one (what the PostToolUse hook wants — the proc under edit). It builds only service
# projects, in Release, to the deterministic bin/ path the differential gate runs.
# The test project is a separate build (gates/unit.sh) so a broken test file can't be
# mistaken for a broken service.
#
# NuGet may print NU1902/NU1903 transitive-dependency advisories (MongoDB.Driver
# pulls SharpCompress/Snappier); those are a Phase-5 SECURITY.md item, not a build
# failure. Only a non-zero dotnet exit fails this gate.
#
#   bash gates/build.sh                                   # every proc in the manifest
#   bash gates/build.sh Integration.GetStockHoldingUpdates
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MANIFEST="generated/runners.json"
PY="${PYTHON:-py}"

log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[1;32m[build] PASS:\033[0m %s\n' "$*"; }

[ -f "$MANIFEST" ] || die "runner manifest not found: $MANIFEST"
command -v "$PY" >/dev/null 2>&1 || die "the '$PY' launcher is required (reads $MANIFEST)"

# Resolve the csproj list: one proc if named, else every proc in the manifest.
resolve_csprojs() {
  if [ "$#" -ge 1 ]; then
    "$PY" - "$MANIFEST" "$1" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
r = m.get(sys.argv[2])
if not r:
    sys.stderr.write(f"proc {sys.argv[2]!r} not in manifest\n"); sys.exit(3)
print(r["csproj"])
PYEOF
  else
    "$PY" - "$MANIFEST" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
for k, r in m.items():
    if k == "//": continue
    print(r["csproj"])
PYEOF
  fi
}

# tr -d '\r': the `py` launcher emits CRLF on Windows, so strip the CR or the path
# carries a trailing \r and every -f test fails.
mapfile -t PROJS < <(resolve_csprojs "$@" | tr -d '\r') || die "could not resolve csproj(s) from $MANIFEST"
[ "${#PROJS[@]}" -gt 0 ] || die "no service projects to build"

for PROJ in "${PROJS[@]}"; do
  [ -f "$PROJ" ] || die "service project not found: $PROJ"
  log "dotnet build -c Release $PROJ"
  dotnet build -c Release --nologo "$PROJ" \
    || die "service does not compile: $PROJ"
done

ok "service(s) build (Release): ${#PROJS[@]} project(s)"
