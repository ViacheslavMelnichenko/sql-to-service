#!/usr/bin/env bash
# Gate tool — task 3.2. Run the agent-written unit tests. These are authored by the
# test-author subagent in a context SEPARATE from the implementer (ADR-0001/0004):
# they assert the service output equals golden after canonicalise.py, so a test
# passing is independent evidence the conversion is right, not the implementer
# marking its own homework.
#
# One test project covers EVERY converted proc: it compiles each service (see the
# <Compile Include> list in the .csproj) and holds one *Tests.cs class per proc, so
# `dotnet test` runs the whole corpus's unit suite in one pass. Each test class seeds
# its OWN isolated Mongo database (wwi_test_<proc>, dropped and recreated per run), so
# this gate needs the Mongo container up on :37017 but does NOT depend on
# seed-mongo.sh having run — it is self-contained. It does need the `py` launcher on
# PATH: the tests shell out to corpus/canonicalise.py for the gate's real normal form
# rather than reimplementing it in C#.
#
#   bash gates/unit.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '\033[1;34m[unit]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[unit] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[1;32m[unit] PASS:\033[0m %s\n' "$*"; }

PROJ="generated/tests/SearchForCustomers.Tests.csproj"
[ -f "$PROJ" ] || die "test project not found: $PROJ"

# The tests connect to Mongo on :37017. Fail with a clear message if it is down,
# rather than letting xunit report an opaque connection timeout.
command -v py >/dev/null 2>&1 || die "the 'py' launcher is required (tests call canonicalise.py)"

log "dotnet test -c Release $PROJ"
dotnet test -c Release --nologo "$PROJ" \
  || die "unit tests failed (is the Mongo container up on :37017?)"

ok "unit tests green"
