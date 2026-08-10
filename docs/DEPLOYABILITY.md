# Deploying this at a client — the honest answer

This repository is a **demonstration of method**, not a shrink-wrapped product. The
question a sharp technical buyer asks in the first meeting is *"could you run this
against our 500-proc backlog, inside our environment, without leaking our data?"* —
and the honest answer has four parts, none of which this demo hand-waves. Naming
the gaps here is the point: a scoped, defensible claim beats an implied one that
collapses under the first follow-up.

## (a) The Claude Code dependency, and the on-prem story

The pipeline is built **on Claude Code** — subagents, skills, hooks, tools are its
native primitives (ADR-0004), and that is deliberate: the labels are backed by real
platform mechanism rather than a wrapper script pretending to be an agent. The cost
of that choice, stated in the ADR, is that **reproduction needs Claude Code**.

What that means for a deployment:

- **The gate does not need it.** Everything that establishes *correctness* —
  `gates/verify.sh`, `gates/differential.sh`, `gates/mutation-check.sh`, the golden
  capture — is deterministic POSIX-sh over committed files and runs with **no model
  call at all** (that is the whole `$0`, audit-it-yourself claim, and it is what CI
  runs). A client can adopt the *gate* — the non-circular oracle, the value
  differential, the mutation catalogue — independently of who or what generates the
  code.
- **The generation step needs a model.** The four-stage agent loop needs Claude
  Code with API access. There is no air-gapped story today: it requires either the
  Anthropic API or a deployment channel that exposes Claude Code (e.g. Amazon
  Bedrock / Google Vertex, where Anthropic models are available inside a cloud
  tenancy the client already trusts). For a truly air-gapped site, the honest answer
  is **"not today"** — the generation half would need re-targeting at whatever model
  runs inside the boundary, and only the gate half ports unchanged.
- **The interface is `claude -p` (headless).** The harness shells out to the CLI, so
  swapping the substrate is a contained change (the runner contract, not the gate).
  That is a design property worth stating, not a shipped adapter.

**Claim to make:** *"The correctness gate is model-agnostic and runs offline for
free; the generator currently requires Claude Code API access."* Not *"deployable
air-gapped."*

## (b) Customer data never belongs in the repo — the masking gap

This is the sharpest one, and the demo sidesteps it only because its corpus is the
public, MIT-licensed WideWorldImporters sample — **no real data exists here to
leak.** The method as shown, applied naively to a client, would not be acceptable:

- `corpus/seed/seed-mongo.sh` re-applies `relational.sql`, then
  `export-relational.py --all-tables` dumps **every base table** to
  `corpus/seed/relational.json`, which is **committed to git**. On the demo that is
  fine — the rows are fictional sample data. On a client it would mean *production
  table contents in a git history*, which is a hard blocker for exactly the
  enterprises that have large T-SQL backlogs.
- **The required step before any client use is a masking / synthesis stage** between
  "read the real schema" and "produce the seed." The seed's job (ADR-0002/0007) is
  *branch coverage* — it must contain rows that discriminate the behaviours the gate
  compares (a NULL contact, an `8.00` that catches the decimal→double mutant), **not**
  real values. That means the correct pipeline is: derive the *shape and the
  branch-covering cases* from the real schema, then **synthesise** rows that exercise
  them — real customer rows never enter the corpus. The golden is then captured from
  the original proc over the *synthetic* seed, and non-circularity is unaffected
  (the oracle still predates the model; it just reads synthetic input).
- Until that stage exists, the honest scope is: *"demonstrated on public sample data;
  a data-synthesis step is a prerequisite for any engagement touching real tables,
  and it is scoped, not built."*

## (c) Secrets — the `.env`-in-argv smell

Today, `seed-mongo.sh` sources `.env` and passes `MSSQL_SA_PASSWORD` to `sqlcmd` via
`-P "$MSSQL_SA_PASSWORD"` on the command line. For a throwaway dev engine torn down
with the job that is acceptable (and CI's password is a runner-only literal, see
`.github/workflows/verify.yml`). In a client environment it is a red flag on two
counts:

- **A secret on argv is visible in the process table** (`ps`, container inspect) to
  any co-tenant of that host, and tends to land in shell history and logs.
- **`.env` on disk** is the wrong place for a production credential.

The client-grade answer, none of which is exotic: pull the credential from a secrets
manager (Vault, AWS/GCP Secrets Manager, or the platform's native store) at run time,
inject it as an environment variable the tool *reads* (not an argv the tool is
*handed*), and prefer a short-lived / least-privilege DB principal over the `sa`
account this demo uses for convenience. `docs/SECURITY.md` carries the specifics.

## (d) What a proc actually costs to onboard

The demo carried **one** proc through the four stages by hand and gated a second; it
has not run the harness live, so any per-proc dollar figure would be invented — and
this project does not invent numbers where a measurement is promised (that is what
the Phase-4 harness and its pre-registration exist to produce). What *can* be stated
honestly is the **shape** of the per-proc cost, so a buyer can reason about scale:

- **Free and mechanical, once per proc:** add a `corpus/cases/<Proc>.json` (its
  cases + params + `ordered` flag) and a `generated/runners.json` entry. The gates
  are proc-agnostic (B.1), so this is the *entire* integration cost on the gate side
  — no script edits.
- **The capture:** run the original proc over the (synthetic) seed to freeze its
  golden. Deterministic, no model.
- **The generation:** one headless agent run through the four stages, bounded by the
  retry cap of 2. This is the only step that spends model budget, and its real
  token/dollar cost per proc is precisely the number the harness is built to
  measure — deliberately unstated until `run-001.json` exists.
- **The ceiling still applies:** only read-only / deterministic / single-result-set
  procs are in scope for *this* harness (see the applicability-ceiling section of the
  root `README.md` and `corpus/SELECTION.md`). A backlog's stateful and
  non-deterministic procs need a different harness and are a separate estimate.

**Claim to make:** *"Per-proc gate integration is near-zero and free; the generation
cost is measured, not asserted, and only the tractable proc tier is in scope."*

## The one-line version

The **gate** — the part that makes the result trustworthy — is portable, offline,
free, and model-agnostic today. The **generator** needs Claude Code API access and a
data-synthesis step before it touches a real database, and its per-proc cost is a
measured number this demo has not yet produced. Sold as *that*, it is a defensible
capability; sold as "deploy it in your air-gapped environment next week," it is an
overreach the first technical question would expose.
