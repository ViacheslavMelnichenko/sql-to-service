#!/usr/bin/env bash
# Eval runner — Phase 4 (B.3). The front door to evals/harness.py.
#
# Two things this wrapper exists to do that the harness deliberately will not do
# for itself:
#
#   1. DEFAULT TO THE SAFE MODE. `bash evals/run.sh` runs the harness in --dry-run:
#      no model, no API spend, no headless agent loop. It exercises every
#      deterministic part of the harness (gates, the SHA-256 identity check, cost
#      accounting shape, JSON emission) against the ALREADY-COMMITTED services and
#      writes evals/results/dry-run.json. This is what CI and a local run use to
#      prove the scaffold is correct for free.
#
#   2. MAKE A LIVE RUN AN EXPLICIT, DELIBERATE ACT. A live run drives `claude -p`
#      headless with tool access and spends real API budget across a multi-agent
#      conversion. The harness refuses to start live unless EVAL_LIVE_OK is set;
#      this script sets it ONLY after the operator types the confirmation, so a
#      live run can never happen by a stray flag or a CI accident.
#
#   bash evals/run.sh                 # dry-run (safe, free, default)
#   bash evals/run.sh --live          # live run-001 — prompts for confirmation
#   bash evals/run.sh --live --yes    # live, non-interactive (CI with a real key)
#
# On Windows, use evals/run-live.ps1 from a PowerShell window you opened yourself
# (not a Claude Code session — the Foundry key is scrubbed from spawned subprocesses).
#
# Prereqs for --live: the two containers up (:11433 / :37017), `claude` on PATH and
# authenticated, and an environment that permits a headless agent loop with tool
# access. The full runbook — both paths, prerequisites, and the auth traps — is
# evals/RUNNING.md; see also docs/architecture.md §5 and evals/PREREGISTRATION.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="${PYTHON:-py}"
command -v "$PY" >/dev/null 2>&1 || PY=python3

LIVE=0
ASSUME_YES=0
PASSTHROUGH=()
for arg in "$@"; do
  case "$arg" in
    --live) LIVE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    *) PASSTHROUGH+=("$arg") ;;
  esac
done

if [ "$LIVE" = "0" ]; then
  echo "[run] dry-run (no model, no API spend). Use --live for a real run-001."
  exec "$PY" evals/harness.py --dry-run "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"
fi

# --- live path: confirm, then authorise via EVAL_LIVE_OK ---------------------------
command -v claude >/dev/null 2>&1 || { echo "[run] 'claude' not on PATH — cannot run live" >&2; exit 1; }

cat >&2 <<'WARN'
[run] LIVE RUN requested.
      This spends REAL API budget and drives a headless agent loop with tool
      access (Write/Edit/Bash under generated/, gated by the repo's hooks). It
      converts the run set through the four-stage pipeline and writes a real,
      citable evals/results/run-001.json.
WARN

if [ "$ASSUME_YES" != "1" ]; then
  printf '[run] type "run-live" to proceed: ' >&2
  read -r reply
  [ "$reply" = "run-live" ] || { echo "[run] aborted — no live run." >&2; exit 1; }
fi

export EVAL_LIVE_OK=1
# k=3 (PREREGISTRATION.md): each live run is ONE independent sample, written to the
# next free run-001.sample-0N.json so a re-run never clobbers an earlier sample.
# After the 3rd, aggregate into the distribution:  "$PY" evals/aggregate.py --expect-k 3
next_sample=1
for existing in evals/results/run-001.sample-*.json; do
  [ -e "$existing" ] || continue
  n="${existing##*sample-}"; n="${n%.json}"; n=$((10#$n))
  [ "$n" -ge "$next_sample" ] && next_sample=$((n + 1))
done
sample_id=$(printf 'run-001.sample-%02d' "$next_sample")
echo "[run] live sample $next_sample of k=3 -> evals/results/$sample_id.json" >&2
exec "$PY" evals/harness.py --run-id "$sample_id" "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"
