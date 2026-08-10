#!/usr/bin/env bash
# PostToolUse hook — task 3.5. After the agent writes to generated/, build the
# service immediately so a compile break surfaces at the moment it is introduced,
# not three tool-calls later when the cause is buried. This is the tightest gate in
# the loop: it runs on every write, so it must be cheap and it must only fire for
# writes that could affect the build.
#
# Claude Code streams the completed tool call as JSON on stdin ({tool_name,
# tool_input:{file_path}}). We only build when a .cs / .csproj under generated/ was
# written — a .md spec or a .json does not change compilation, and rebuilding on
# those would just add latency. When it does fire, it runs gates/build.sh.
#
# Exit convention: exit 2 feeds stderr back to the agent (a build break becomes a
# correction it must fix before proceeding); exit 0 is silent success. We never
# hard-fail the session on a non-build tool call.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
PY="$(command -v py || command -v python3 || true)"

# Extract the written path; if we can't, do nothing (a PostToolUse hook must not
# block the loop on its own parsing trouble — the PreToolUse guard is fail-closed,
# this one is advisory).
path=""
if [ -n "$PY" ]; then
  path="$("$PY" -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print((d.get("tool_input") or {}).get("file_path",""))
except Exception:
    print("")' 2>/dev/null || true)"
fi

case "$path" in
  *generated/*.cs|*generated/*.csproj|*generated\\*.cs|*generated\\*.csproj) ;;
  *) exit 0 ;;  # not a build input — nothing to do
esac

echo "[post-write-build] $path changed → building" >&2
if bash gates/build.sh >/tmp/post-write-build.log 2>&1; then
  exit 0
fi
echo "[post-write-build] build FAILED after writing $path:" >&2
tail -30 /tmp/post-write-build.log >&2
exit 2  # feed the failure back to the agent as a correction
