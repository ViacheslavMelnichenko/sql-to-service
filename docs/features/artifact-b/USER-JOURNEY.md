---
feature: artifact-b
slug: artifact-b
updated_at: 2026-08-07
status: draft
owner: Viacheslav Melnichenko
companions: [IMPLEMENTATION-PLAN.md, SUCCESS-CRITERIA.md, METHODOLOGY.md]
---

# Artifact B — Reviewer User Journey

The other three documents assume a reviewer who *runs* the artifact. Almost none
do. This document designs for who actually shows up, in what order they read, and
what they conclude — and it turns those conclusions into build-order and a few
deliverables the plan was missing.

**Governing decision (made 2026-08-07):** the single run path is the full
`docker compose` + `.bak` restore (production-realistic, ~10+ min, RAM-dependent).
No lightweight no-Docker path. **Direct consequence:** realistically very few
reviewers finish a run, so the README and the *committed* artifacts must carry
~100 % of the signal on their own. Running is the skeptic's audit trail, not the
main channel. Everything below follows from that.

---

## 1. Who actually arrives

Three readers, not one. We had designed only for the third.

| Reader | Time | What they do | What wins them |
| --- | --- | --- | --- |
| **Recruiter / screener** | 10–20 s | glances: empty or not, fresh or stale | pinned repo, README H1, last-commit recency, **green CI badge** |
| **Hiring manager / lead** | 60–90 s | reads first README screen, opens 1–2 files | "real work or tutorial? did they measure?" |
| **Senior engineer (interview)** | 5–15 min | reads ADRs, opens `generated/`, hunts a hole in the gate | "does this survive three follow-up questions?" |

The recruiter is a reader we had ignored entirely. They never read prose — they
pattern-match on **freshness + a green badge + a non-empty first screen**. If the
badge is missing or red, or the last commit is 8 months old, the link is dead
before the manager ever sees it.

---

## 2. Hard prerequisites (without these, the journey never starts)

- **The repo MUST be public.** `cv` is private; `sql-to-service` is the public
  face. A private repo is a dead link in the résumé — the entire artifact is
  wasted. Verify before pinning.
- **Pinned on the GitHub profile.** An unpinned repo is invisible below the fold.
- **Green CI badge on line 1 of the README.** This is the recruiter's entire
  signal and the manager's first. `verify.yml` (free, no model calls) is what
  makes it green and *keeps* it green on every push — its real job is to be a
  badge that proves "the committed output passes its own gates" without anyone
  running anything.
- **Recent commit date.** Stale reads as abandoned. Not gameable dishonestly, but
  the work should land in a tight window so the profile looks alive.

---

## 3. The journey, frame by frame

### Frame 1 — first README screen (the 60-second verdict)

This screen carries the artifact. It must answer, above the fold, without
scrolling:

1. **What is this?** — one sentence: an agentic T-SQL→.NET/Mongo pipeline gated by
   differential testing against the original procedures' output.
2. **Does it work?** — green CI badge + the results table (Table 1).
3. **Did they measure?** — the failure taxonomy link (Table 2) + the cost delta.
4. **Why trust it?** — one line on the non-circular gate ("golden output captured
   from the original procedure before any model runs").

**The missing deliverable — a "read it without running" chain.** The skeptic who
won't run docker still wants to verify one case. So the README links a single
worked example that can be followed in two clicks, entirely in committed files:

> **See one conversion end to end (no setup):**
> [`corpus/procs/Website.SearchForCustomers.sql`](...) →
> [`generated/.../SearchForCustomersService.cs`](...) →
> [`corpus/golden/Website.SearchForCustomers.json`](...) →
> [its record in `evals/results/run-002.json`](...)

That chain — source, generated code, golden output, the differential verdict, the
cost — is the whole thesis, readable in a browser in 90 seconds with zero
infrastructure. Given the heavy run path, this chain is the *primary* proof
channel, not a footnote.

### Frame 2 — browsing (the +2-minute judgment)

Whatever they open next, they judge instantly. So each must be its best foot:

- **`generated/`** — they will judge *code quality*, not pipeline quality. So the
  linked example must be a **substantive** conversion (a `SearchFor*` with real
  joins / CASE / relevance ordering), not the shortest one. A trivial lookup here
  reads as "the pipeline only does trivial things."
- **one ADR** — they check whether these are real decisions or decoration. ADR-1
  (differential testing) and ADR-6 (criterion + mechanical Mongo seed) are the
  strongest; the README links directly to one, not to the folder.
- **`evals/results/summary.md`** — Table 2 and its analysis paragraph. This
  paragraph ("what the differential failures had in common") is specifically what
  a senior reads as proof you looked at the failures. It is load-bearing.

### Frame 3 — the run (the 1-in-20 skeptic, 10+ min)

They chose to audit. This is where trust is won or lost on **first impression of
the run**, and our run is heavy. So the run's UX is a real deliverable:

- **The README states the cost honestly up front:** "Reproducing from scratch
  restores a ~GB sample DB and takes ~10–15 min; the committed results above need
  no run." No surprise, no stall-with-no-explanation.
- **`restore.sh` prints progress and preconditions** (RAM needed, ports used) and
  **fails loudly with a fix**, never hangs silently. A silent 5-minute pause is
  read as "broken."
- **`verify.sh` is the payoff:** it runs build + unit + differential against the
  committed output and prints a per-proc PASS/FAIL that **reproduces the published
  table**. The reviewer sees the README's numbers regenerate in front of them,
  with no model calls. That equivalence — published table == what verify prints —
  is the audit closing.
- **Regeneration (paid, model calls) is explicitly a separate, opt-in command.**
  Nobody is surprised by a bill.

---

## 4. What we want them to conclude — and the failure modes

**Target takeaway (one sentence):** *"This person builds agentic systems like an
engineer — gates, measurement, honesty about failure — not a ChatGPT demo."*

The journey succeeds only if it pre-empts each dismissal a senior actually reaches
for:

| Likely dismissal | Where it's prevented |
| --- | --- |
| "Nice README, but the code is 200 lines that do nothing" | Frame 2: linked `generated/` example is substantive, not shortest |
| "Numbers look good but I can't check them and won't run it" | Frame 1: read-without-running chain; Frame 3: verify reproduces the table |
| "It's just a lookup converter" | corpus includes `SearchFor*` with real joins (plan §5.2) |
| "Too perfect — smells curated" | honest pass rate + `flaky` class + visible taxonomy (methodology §2, §7) |
| "The tests are agent-written, so the gate is circular" | Frame 1 line 4 + ADR-1; golden captured before any model |
| "Cheaper run-002 is just warm cache" | METHODOLOGY §5 cold-cache control, stated in METHOD.md |
| "Dead link / stale / private" | §2 prerequisites |

Any dismissal with no cell in the right column is an open journey risk.

---

## 5. New / sharpened deliverables this journey implies

Not in the plan, or under-specified there. Each is small:

- **DJ1 — CI badge + `verify.yml` green on push.** The recruiter's entire signal.
  (Plan had `verify.yml`; the *badge* and its first-line placement are the
  journey requirement.)
- **DJ2 — Read-without-running chain in the README.** The 4-link worked example
  (source→generated→golden→record). The primary proof channel given the heavy
  run. Pick the example proc deliberately (substantive, and one that *cleared*).
- **DJ3 — A designated showcase conversion in `generated/`.** One conversion that
  is the "open this first" example — chosen for code quality, not brevity.
- **DJ4 — Honest run-cost note + loud-failing `restore.sh`.** Sets expectation
  before the 10-min run and prevents the silent-stall dismissal.
- **DJ5 — verify.sh output that visibly reproduces the published table.** The
  audit closing: published numbers == what the machine prints, no model calls.
- **DJ6 — "What this is not" + demo-vs-engagement firewall on the first screen.**
  Pre-stating scope limits is credibility, not modesty (plan §0.1, SC §3.4).

---

## 6. Build-order consequence (this is why the journey matters now)

The journey reorders the build. README and committed artifacts carry the signal,
so they are not the *last* evening — they are drafted *first* and kept true:

1. **Draft the README first screen before writing the pipeline** — it is the
   spec for what the pipeline must produce (the plan already says "design the
   first screen first"; the journey makes it literal). A placeholder table with
   the exact columns forces the metrics schema to match what the reader needs.
2. **Pick the showcase proc early** (DJ2/DJ3) so the substantive example exists
   from the first end-to-end run, not retrofitted.
3. **`verify.sh` reproducing the table** is a Frame-3 requirement, so its output
   format is designed alongside `summary.md`, not after.
4. **CI badge lands the moment `verify.yml` is green**, not in the final polish
   evening — a green badge early also keeps every later push honest.

Everything else (full corpus, optimization pass, run-002) proceeds per the plan.
The journey doesn't add scope so much as **reorder** it around the reader who
never runs anything.

---

## 7. The one-line test for every artifact decision

> *Does this change what the reviewer concludes in the 90 seconds they actually
> spend — or only in the 10 minutes they won't?*

Optimize the first. The run path exists to make the artifact **falsifiable**, not
to be the experience. That is the whole reframing.

---

## 8. Introduced specifics (overrule cheaply)

- **Three-reader model** (recruiter / manager / senior) with the recruiter added
  as a first-class, prose-blind reader driven by badge + freshness.
- **Read-without-running 4-link chain (DJ2)** as the primary proof channel,
  promoted because the run path is deliberately heavy.
- **Designated showcase conversion (DJ3)** chosen for code quality over brevity.
- **verify.sh == published table** as the explicit audit-closing property (DJ5).
- **README-first build order** — the first screen is drafted before the pipeline
  and used as its output spec.
