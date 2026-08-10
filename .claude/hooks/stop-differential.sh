#!/usr/bin/env bash
# Stop hook — task 3.6. The agent may not declare itself done until the differential
# is green. This is the loop's terminal gate: PostToolUse proves it compiles, this
# proves it is CORRECT against the golden (ADR-0001). Without it, an agent could
# stop on a service that builds and reads plausibly but returns the wrong rows —
# exactly the failure the whole artifact exists to catch.
#
# Claude Code runs the Stop hook when the agent tries to end its turn. Exit 0 lets
# it stop; exit 2 BLOCKS the stop and feeds stderr back, so a red differential turns
# into "keep going, here is what still fails" — the in-loop half of the retry
# protocol (pipeline/retry.md). The retry CAP is enforced by the harness, not here:
# this hook's only job is the honest verdict, every time it is asked.
#
# It runs gates/differential.sh (which seeds Mongo itself), i.e. the same gate a
# human or CI runs — no special path for the agent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if bash gates/differential.sh >/tmp/stop-differential.log 2>&1; then
  echo "[stop-differential] differential green — agent may stop" >&2
  exit 0
fi

echo "[stop-differential] differential is RED — not done yet. Failing cases:" >&2
# Surface just the per-case lines and the final FAIL, not the whole build log.
grep -E '✗|DIFFERS|FAIL|MISSING' /tmp/stop-differential.log >&2 || tail -20 /tmp/stop-differential.log >&2
echo "[stop-differential] fix the service under generated/ until every case is identical to golden, then stop." >&2
exit 2
