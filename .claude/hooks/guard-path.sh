#!/usr/bin/env bash
# PreToolUse hook — task 3.7. Block any Write/Edit whose target is OUTSIDE the
# folders the conversion loop is allowed to touch. The pipeline's contract
# (ADR-0001/0004) is that the agents produce code under generated/ and NOTHING
# else: the oracle (corpus/), the ADRs (docs/), the gate scripts (gates/) and the
# agent/skill definitions (.claude/) must survive the run untouched, or a green
# gate could just mean the agent edited the golden to match its own output.
#
# Claude Code streams the tool call as JSON on stdin ({tool_name, tool_input:{
# file_path,...}}). We resolve file_path against the repo root and allow it only if
# it lands under generated/ (or the OS temp dir, for scratch). Anything else exits
# non-zero: exit 2 tells Claude Code to BLOCK the tool call and feed our stderr back
# to the agent, so the block is also a correction ("write under generated/").
#
# Fail-closed: if we cannot parse the path, we block. A guard that fails open is not
# a guard.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY="$(command -v py || command -v python3 || true)"
[ -n "$PY" ] || { echo "[guard-path] no python (py/python3) on PATH — blocking to fail closed" >&2; exit 2; }

"$PY" "$ROOT/.claude/hooks/guard_path.py" "$ROOT"
