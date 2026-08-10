#!/usr/bin/env python3
"""PreToolUse path guard (task 3.7) — the logic behind guard-path.sh.

Reads the Claude Code tool-call JSON from stdin and decides whether a Write/Edit is
allowed. The rule (ADR-0001/0004): the conversion loop may only create/modify files
under `generated/`. Everything the gate's authority rests on — the golden oracle in
`corpus/`, the ADRs in `docs/`, the gate scripts in `gates/`, the agent/skill
definitions in `.claude/` — is OFF LIMITS to the agent, so a passing gate can never
mean "the agent edited the oracle to match its output."

Contract with Claude Code:
  * exit 0  -> allow the tool call (path is inside generated/, or not a file write).
  * exit 2  -> BLOCK the tool call; stderr is fed back to the agent as a correction.
Fail closed: any parse failure or unresolvable path blocks (exit 2). A guard that
fails open is not a guard.
"""
from __future__ import annotations

import json
import os
import sys

# Tool calls that write to disk. Non-write tools (Read, Grep, Bash, ...) are not
# our concern here — Bash is covered by its own allow-listing, and this hook is
# wired to Write|Edit only in settings.json, but we re-check defensively.
WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}

# Folders the loop may write to, relative to repo root. generated/ is the only
# real one; the OS temp dir is allowed so scratch files don't trip the guard.
ALLOWED_SUBDIRS = ("generated",)


def _block(msg: str) -> "int":
    sys.stderr.write(f"[guard-path] BLOCKED: {msg}\n")
    sys.stderr.write("[guard-path] the conversion loop may only write under generated/. "
                     "Put the file there; corpus/, docs/, gates/ and .claude/ are the "
                     "oracle and the rules and must stay untouched (ADR-0001/0004).\n")
    return 2


def main() -> int:
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return _block("could not parse the tool-call JSON on stdin")

    tool = payload.get("tool_name", "")
    if tool not in WRITE_TOOLS:
        return 0  # not a write — nothing to guard

    file_path = (payload.get("tool_input") or {}).get("file_path")
    if not file_path:
        return _block(f"{tool} with no file_path — cannot verify the target")

    target = os.path.abspath(file_path)

    # Allowed if under any allowed subdir of the repo, or under the OS temp dir.
    allowed_roots = [os.path.join(root, d) for d in ALLOWED_SUBDIRS]
    tmp = os.environ.get("TMPDIR") or os.environ.get("TEMP") or "/tmp"
    allowed_roots.append(os.path.abspath(tmp))

    for base in allowed_roots:
        try:
            if os.path.commonpath([target, base]) == base:
                return 0
        except ValueError:
            # Different drive on Windows — commonpath raises; treat as not-under.
            continue

    return _block(f"{tool} -> {target} is outside the allowed folders")


if __name__ == "__main__":
    raise SystemExit(main())
