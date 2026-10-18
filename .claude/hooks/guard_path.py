#!/usr/bin/env python3
"""PreToolUse path guard (task 3.7) — the logic behind guard-path.sh.

Reads the Claude Code tool-call JSON from stdin and decides whether a write is
allowed. The rule (ADR-0001/0004): the conversion loop may only create/modify files
under `generated/`. Everything the gate's authority rests on — the golden oracle in
`corpus/`, the ADRs in `docs/`, the gate scripts in `gates/`, the agent/skill
definitions in `.claude/` — is OFF LIMITS to the agent, so a passing gate can never
mean "the agent edited the oracle to match its output."

Two tool classes are guarded:
  * Write/Edit/MultiEdit/NotebookEdit — the file-write tools. Blocked unless the
    target resolves under generated/ (or the OS temp dir, for scratch).
  * Bash — defence in depth. The implementer also has Bash, so a shell redirection
    or a mutating command (`cp`, `mv`, `rm`, `sed -i`, `git checkout`, ...) could
    otherwise reach the oracle without ever touching Write/Edit and falsely-green the
    in-session Stop gate. We block a Bash call that BOTH looks like it writes AND
    names a protected path. This is a heuristic — a determined, obfuscated command
    can still slip past (e.g. building the path at runtime) — so it is a bar-raiser,
    not a sandbox; the non-bypassable backstop remains a fresh-checkout verify.sh,
    which re-derives the published numbers from the committed oracle regardless of
    anything the loop did.

Contract with Claude Code:
  * exit 0  -> allow the tool call.
  * exit 2  -> BLOCK the tool call; stderr is fed back to the agent as a correction.
Fail closed: any parse failure or unresolvable path blocks (exit 2). A guard that
fails open is not a guard.
"""
from __future__ import annotations

import json
import os
import re
import sys

# Tool calls that write to disk directly.
WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}

# Folders the loop may write to, relative to repo root. generated/ is the only
# real one; the OS temp dir is allowed so scratch files don't trip the guard.
ALLOWED_SUBDIRS = ("generated",)

# Top-level dirs that hold the oracle, the rules, and the gate — OFF LIMITS to the
# loop no matter the tool. (generated/ is deliberately NOT here: it is the one place
# the loop is meant to write.)
PROTECTED_DIRS = ("corpus", "docs", "gates", "pipeline", "evals", ".claude")

# Bash utilities that mutate the filesystem. If one of these appears AND a protected
# path is named in the same command, we block.
_MUTATORS = (
    "cp", "mv", "rm", "tee", "dd", "truncate", "install", "ln",
    "chmod", "chown", "rsync", "mkdir", "touch", "shred",
)
# A path token under a protected dir, relative or ./-prefixed, in quotes or bare.
_PROTECTED_TOKEN = re.compile(
    r"""(?:^|[\s'"=(<>|&;])\.?/?(?:""" + "|".join(re.escape(d) for d in PROTECTED_DIRS) + r""")[/\\]"""
)
# A shell redirection ( > or >> ) and its target.
_REDIRECT = re.compile(r">>?\s*(['\"]?)([^\s'\";|&]+)\1")


def _block(msg: str) -> int:
    sys.stderr.write(f"[guard-path] BLOCKED: {msg}\n")
    sys.stderr.write("[guard-path] the conversion loop may only write under generated/. "
                     "corpus/, docs/, gates/, pipeline/, evals/ and .claude/ are the "
                     "oracle and the rules and must stay untouched (ADR-0001/0004).\n")
    return 2


def _is_protected_path(token: str) -> bool:
    """True if a path token points under a protected top-level dir."""
    t = token.strip().strip("'\"").replace("\\", "/")
    if t.startswith("./"):
        t = t[2:]
    first = t.split("/", 1)[0]
    return first in PROTECTED_DIRS


def _guard_bash(command: str) -> int:
    """Block a Bash command that writes to a protected path. Allows reads and any
    write that stays under generated/ or doesn't name a protected dir."""
    if not command:
        return 0  # nothing to inspect — allow

    # 1) Redirection whose target is a protected path (e.g. `echo x > corpus/..`).
    for _q, target in _REDIRECT.findall(command):
        if _is_protected_path(target):
            return _block(f"Bash redirects to a protected path: {target}")

    mentions_protected = bool(_PROTECTED_TOKEN.search(command))
    if not mentions_protected:
        return 0  # no protected path named — the oracle is safe

    # 2) In-place edit of a protected file (sed -i / perl -i).
    if re.search(r"\b(?:sed|perl)\b[^\n]*\s-i", command):
        return _block("Bash sed/perl -i in-place edit of a protected path")

    # 3) A mutating utility naming a protected path.
    if re.search(r"\b(?:" + "|".join(_MUTATORS) + r")\b", command):
        return _block("Bash mutating command (cp/mv/rm/...) touching a protected path")

    # 4) A git command that could rewrite the oracle from history.
    if re.search(r"\bgit\s+(?:checkout|restore|reset|rm|clean)\b", command):
        return _block("Bash git mutation (checkout/restore/reset/rm/clean) of a protected path")

    return 0  # names a protected path but only reads it — allow


def main() -> int:
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return _block("could not parse the tool-call JSON on stdin")

    tool = payload.get("tool_name", "")

    if tool == "Bash":
        return _guard_bash((payload.get("tool_input") or {}).get("command", "") or "")

    if tool not in WRITE_TOOLS:
        return 0  # not a guarded tool — nothing to do

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
