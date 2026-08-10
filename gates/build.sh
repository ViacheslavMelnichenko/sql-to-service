#!/usr/bin/env bash
# Gate tool — task 3.1. Build the generated service. The first gate the pipeline
# runs after the implementer writes code: does it even compile? A conversion that
# does not build cannot be differentially tested, so this fails fast and loud
# before the unit and differential gates are attempted.
#
# It builds ONLY the service project (generated/SearchForCustomers.csproj), in
# Release, to the deterministic bin/ path the differential gate then runs. The test
# project is a separate build (gates/unit.sh) so a broken test file can't be
# mistaken for a broken service.
#
# NuGet may print NU1902/NU1903 transitive-dependency advisories (MongoDB.Driver
# pulls SharpCompress/Snappier); those are a Phase-5 SECURITY.md item, not a build
# failure. Only a non-zero dotnet exit fails this gate.
#
#   bash gates/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[1;32m[build] PASS:\033[0m %s\n' "$*"; }

PROJ="generated/SearchForCustomers.csproj"
[ -f "$PROJ" ] || die "service project not found: $PROJ"

log "dotnet build -c Release $PROJ"
dotnet build -c Release --nologo "$PROJ" \
  || die "service does not compile"

ok "service builds (Release)"
