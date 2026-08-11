# Running the harness — the operational runbook

Everything needed to go from a clean checkout to a citable `run-001.json`. The
*why* lives in [`../docs/architecture.md`](../docs/architecture.md) §5 and
[`PREREGISTRATION.md`](PREREGISTRATION.md); this is the *how*, with the
environment traps that cost real debugging cycles called out inline.

There are two things you might run, and they are not the same:

| | Command | Model? | Cost | Writes |
|---|---|---|---|---|
| **Dry run** (scaffold check) | `bash evals/run.sh` | no | $0 | `evals/results/dry-run.json` (gitignored) |
| **Live run** (the real result) | `bash evals/run.sh --live` | yes | real API budget | `evals/results/run-001.json` |

The dry run measures the **already-committed** services with no model in the loop
— it proves the plumbing (gates, SHA-256 identity, JSON emission) for free. The
live run drives the real agent, headless, through the four-stage pipeline. Only
the live run produces a citable result; a dry run must **never** be renamed to
`run-001` (`harness.py` marks its mode so it can't be mistaken).

---

## Prerequisites

1. **The two engines up and healthy** — SQL Server on `:11433`, MongoDB on
   `:37017`, via the repo's own `docker-compose.yml`:

   ```sh
   cp .env.example .env      # set a SA password that meets SQL Server complexity
   docker compose up -d mssql mongo
   ```

   The seed path shells in with `docker compose exec`, so the containers must be
   compose-managed (not stood up by hand).

2. **`pymongo`** on the Python that runs the harness — it loads the Mongo seed:

   ```sh
   py -m pip install --quiet pymongo      # or: python3 -m pip install pymongo
   ```

3. **The corpus restored + golden present** — `corpus/golden/*.json` must exist
   (they are committed; `corpus/restore.sh` regenerates them if needed). The gate
   compares against these.

Live run only, additionally:

4. **`claude` on PATH and authenticated.** Verify with one cheap call:

   ```sh
   claude -p --output-format json --model claude-opus-4-8-gateway 'Reply with the single word: ok'
   ```

   `"is_error":false` and `"provider":"foundry"` means you are good. See
   **Authentication** below if it fails.

---

## The dry run (free, always do this first)

```sh
bash evals/run.sh
```

This runs `harness.py --dry-run` over every proc in `generated/runners.json` and
writes `evals/results/dry-run.json`. **Read the last line:** `(N/N
cleared_within_cap)` where N is the proc count means the scaffold is green — every
committed service still clears its gate and is SHA-identical to golden. Anything
less is a real regression in a committed artifact, and the harness exits non-zero
so CI catches it.

Run this before every commit that touches `generated/`, `gates/`, `corpus/`, or
`evals/`. It is the same thing CI runs, at $0.

---

## The live run (paid, produces `run-001.json`)

### On macOS / Linux

```sh
bash evals/run.sh --live          # prompts: type "run-live" to confirm
bash evals/run.sh --live --yes    # non-interactive (a real key in the environment)
```

The wrapper refuses to start live unless you confirm, then sets `EVAL_LIVE_OK=1`
and hands off to `harness.py --run-id run-001`. A live run always exits 0 — an
honest failure is a valid result, not a harness error.

### On Windows

Use the PowerShell launcher, and **run it from a PowerShell window you opened
yourself** — not from inside a Claude Code session, and not through the Bash tool:

```powershell
cd C:\projects\sql-to-service
powershell -ExecutionPolicy Bypass -File evals\run-live.ps1
```

`run-live.ps1` does the whole sequence: checks the Foundry key is visible, probes
auth cheaply before spending anything, brings the engines up, waits on the ports,
ensures `pymongo`, then runs the live harness. Expect **tens of minutes per proc**
and a real bill.

Why "a window you opened yourself" is load-bearing: see **Authentication** below.

### What a good result looks like

Each proc records `outcome: "cleared"`, a non-zero `num_turns`/`cost_usd`, a
`model_snapshot` (e.g. `claude-opus-4-8`), and an `identity.match: true` with the
two SHA-256 hashes equal. `cleared_within_cap` at the top is the count that
cleared. A proc landing in `failed:differential` or `flaky` is an **expected,
honest** outcome (PREREGISTRATION.md, H3) — a clean sweep is a finding to
investigate, not a success.

---

## Authentication (why the Windows path is fussy)

The `claude` CLI here reaches the model through **Anthropic Foundry**
(`CLAUDE_CODE_USE_FOUNDRY=1`), authenticated with `ANTHROPIC_FOUNDRY_API_KEY`
against the named resource `ANTHROPIC_FOUNDRY_RESOURCE`. A machine already set up
for Claude Code has these in its environment; you almost never set them by hand.

The trap: **`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`** (a common interactive default)
strips that secret key from **any subprocess Claude Code spawns** — the Bash tool,
`!` in-session commands, background tasks. So a live run launched *through* a
Claude Code session cannot authenticate: the key is gone before `claude -p` sees
it. A plain terminal you opened yourself is not scrubbed, which is why the runbook
insists on one.

The harness itself sets `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0` for the child
`claude` it spawns — with the scrub left on, the CLI silently forces its
permission mode back to `default` and ignores `--permission-mode acceptEdits`, so
the headless agent can never write a file and every attempt ends with 0 turns.

---

## Diagnosing a failing live run

If a live run comes back all-`failed:build` with **0 tokens / 0 turns /
`model_snapshot: null`**, the model never actually ran — something in the
environment aborted each `claude -p` before it produced a turn. Don't guess; capture
the raw output. On Windows:

```powershell
cd C:\projects\sql-to-service
powershell -ExecutionPolicy Bypass -File evals\debug-one.ps1
```

`debug-one.ps1` drives **one** proc with `EVAL_DEBUG=1`, printing the raw `claude
-p` output verbatim and writing every attempt's claude/gate output to
`evals\results\debug\` (gitignored). `EVAL_DEBUG=1` works with any invocation, not
just the launcher:

```sh
EVAL_DEBUG=1 bash evals/run.sh --live --yes
```

Known environment failures this surfaces (all seen on Windows, all now handled by
the harness, but worth recognising if the environment shifts):

- **`Error: Input must be provided ... through stdin or a prompt argument`** — the
  trailing prompt argument was dropped by the Windows `claude.cmd` shim. The
  harness feeds the prompt over **stdin** to avoid this.
- **`Permission mode forced to default ... CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is
  set`** — the scrub downgrade described above. The harness sets the scrub to `0`
  for the child.
- **`execvpe(/bin/bash) failed: No such file or directory` / `wsl: Unknown key`**
  in a gate output — the `bash` first on PATH is a broken WSL, not Git Bash. The
  harness resolves Git Bash explicitly (`EVAL_BASH` overrides); the resolved path
  is recorded in the result as `gate_bash`.

---

## Environment overrides

| Variable | Effect | Default |
|---|---|---|
| `EVAL_MODEL` | `--model` string the harness passes to `claude` | `claude-opus-4-8-gateway` |
| `EVAL_BASH` | which `bash` runs the gate scripts | Git Bash on Windows, `bash` elsewhere |
| `EVAL_DEBUG` | when set, dump raw claude/gate output per attempt to `evals/results/debug/` | off |
| `EVAL_LIVE_OK` | must be set for a live run; `run.sh`/`run-live.ps1` set it after confirmation | unset (refuses live) |
| `PYTHON` | Python launcher the gate scripts use | `py`, falling back to `python3` |
| `MONGO_URI` | Mongo connection the runner/gate use | `mongodb://localhost:37017/wwi` |

---

## Reproducing k=3 and the baseline

- **k=3 (`run-002`, distribution):** run the live harness three times with distinct
  `--run-id`s (`run-001`, `run-002`, `run-003`) and report the distribution, flagging
  any proc whose outcome differs across runs as `flaky` (PREREGISTRATION.md, H3).
- **Baseline (`baseline.json`, B.4):** the naive single-prompt control — same procs,
  same gate, no staged subagents — is what `run-001` must beat (H2).

Both write into `evals/results/` and are read honestly against the same
pre-registered metric; see [`results/README.md`](results/README.md) for how to read
a result file.
