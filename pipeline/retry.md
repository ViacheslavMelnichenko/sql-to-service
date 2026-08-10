# Retry protocol — gate failure fed back to the agent (cap 2)

*Task 3.8. This is the loop's error path: what happens when a gate says "no."*

## The two halves

A gate failure has to reach the agent as a **correction it can act on**, not as a
silent dead end. That correction is delivered in two places, and the split is
deliberate:

1. **In-loop, by hooks (this repo, `.claude/settings.json`).** The hooks are the
   fast half — they fire inside a single agent turn and feed the failure straight
   back via the exit-2 convention (Claude Code re-injects a non-zero hook's stderr
   as a correction the agent must address before proceeding):

   | Hook | Event | Fails when | What the agent gets back |
   |------|-------|-----------|--------------------------|
   | `post-write-build.sh` | `PostToolUse` (Write/Edit) | a `.cs`/`.csproj` under `generated/` no longer compiles | the tail of the build log — the compile error, at the moment it was introduced |
   | `stop-differential.sh` | `Stop` | the agent tries to finish while the differential is red | the failing cases (`✗ / DIFFERS / MISSING`) vs golden |
   | `guard-path.sh` | `PreToolUse` (Write/Edit) | a write targets anything outside `generated/` | "write under generated/; the oracle and rules are off limits" |

   `build` and `differential` are *corrective* retries — the agent reads the
   feedback and edits again. `guard-path` is a *hard* block: there is no retry that
   makes writing the oracle acceptable, so it just refuses (ADR-0001/0004).

2. **Across attempts, by the harness (Phase 4, `evals/harness.py`).** The hooks
   have no memory — a `Stop` hook will block a red finish every time it is asked,
   forever. The **cap lives in the harness**, not in the hooks: it counts attempts
   and, after the cap, stops re-prompting and records the proc as a failure with
   its last gate output. This keeps a genuinely-stuck conversion from looping until
   it burns the budget, and it keeps the failure *honest* — a proc that needed
   three tries is not silently upgraded to a pass.

## The cap: 2

**Two retries after the first attempt** (three attempts total), then the harness
gives up and records the failure.

- **Why a cap at all.** Without one, a hook that correctly refuses a wrong
  conversion becomes an infinite loop — the agent keeps finishing, `Stop` keeps
  blocking, nothing converges. The cap is what turns "never lies" into "never lies
  *and* always terminates."
- **Why 2 and not more.** The failure modes that survive one corrective round tend
  to be structural (a misread join, a wrong ordering key) rather than typos, and
  those rarely resolve by trying the *same* agent on the *same* prompt a fourth
  time — they resolve by a human reading the trace. Past two retries the marginal
  pass rate does not pay for the tokens. Preferring the smaller number keeps the
  headline honest: a high pass-rate that quietly leaned on ten retries is not the
  same result as one that held at a cap of two.
- **The count is per proc, not per session.** Each conversion gets its own budget;
  one hard proc cannot spend another's retries.

## What a retry is *not*

- **Not a way past the guard.** `guard-path` failures do not count against the cap
  and do not earn a retry — they are refusals, not corrections. The fix is to write
  the right file, which is a different action, not the same one again.
- **Not a seed or gate edit.** The retry loop only ever edits code under
  `generated/`. If every retry fails identically, that is a signal to inspect the
  gate or the seed by hand (ADR-0002/0006) — never to loosen the comparison so the
  red goes green. A retry earns a pass by fixing the code, or it does not earn one.

## Cross-references

- Gate scripts the hooks call: `gates/build.sh`, `gates/differential.sh`.
- Why the gate is trustworthy in the first place: `docs/adr/0001-non-circular-gate.md`.
- Why the differential is proven to have teeth: `docs/adr/0006-mutation-validation.md`
  and `gates/mutation-check.sh`.
- Where the cap is enforced and the outcome recorded: `evals/harness.py` (Phase 4).
