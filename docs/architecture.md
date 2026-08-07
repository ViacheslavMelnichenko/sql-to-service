# The Gate Is the Argument: Converting Legacy T-SQL to a .NET + MongoDB Service Layer with Agents

Most write-ups about using agents to modernize legacy code stop at the demo:
point a model at a stored procedure, watch it emit a tidy service class, ship
the screenshot. That demo is real, and it is the least interesting part of the
problem. Making an agent convert *one* procedure is a prompt. Making it convert
hundreds, converge on correct output, stay inside a budget, and keep pace with a
source that refuses to hold still — that is a system, and systems are where the
engineering lives.

This is a write-up about the design of such a system: an agentic pipeline that
re-expresses legacy T-SQL stored procedures as a modern .NET service layer over
MongoDB. It contains no specifics of any engagement I have worked on. It is about
the shape of the problem and the trade-offs it forces, and its spine is a single
question — *how do you know the agent's output is correct?* — because everything
else in the design is downstream of the answer.

## The problem

A payment domain accumulates logic the way a hull accumulates barnacles. Years
of business rules — validation, money movement, settlement timing,
reconciliation, retry semantics — end up expressed as stored procedures, because
that is where the data was and that is where the deadline pointed. The task is to
re-express that logic as a modern .NET service layer with MongoDB underneath: the
procedures becoming methods, the result sets becoming documents, the implicit
contracts becoming explicit ones.

The scale — hundreds of procedures — is not the interesting part; it only means
the hard problems repeat. Two other facts are what make this different from a
greenfield build. First, the source keeps changing: the migration takes months
and the procedures are still in production, still being patched, because the
business does not freeze its rules for the convenience of a migration. Second, a
wrong conversion here is not a cosmetic defect. A decimal truncated in the wrong
place, a NULL read as a zero, a settlement dated to the wrong day — that is money
moved incorrectly. Correctness is not a quality goal in this domain. It is the
product. The interesting question is therefore not *can an agent write the .NET* —
it can — but *how do you know the .NET it wrote is correct*, and how do you keep
knowing it as the source moves underneath you.

## Why "just prompt it" collapses

The naive approach — one big prompt, the whole source tree in context, "port this
to .NET and MongoDB" — works in a demo and fails at scale, in four specific ways.
Each one shapes the pipeline that follows, so each is worth naming.

**Context exhaustion.** A real procedure pulls in table schemas, user-defined
types, the procedures it calls, and shared functions. The dependency closure does
not fit in a context window, and where it fits, attention degrades well before the
token limit. The model that read procedure 200 is not the sharp reader it was at
procedure 3.

**Plausible-but-wrong output that compiles.** This is the dangerous failure, not
the obvious one. A model is very good at producing .NET that looks like correct
.NET: it builds, it passes a linter, it reads like something a competent engineer
wrote — and it has quietly changed the rounding behaviour of a monetary
calculation. Compilation checks grammar, not meaning.

**Silent semantic drift.** The dangerous conversions are the ones that are almost
right, and across hundreds of them the small deviations accumulate. No single one
trips an alarm. Together they mean the new service is *almost* the old one, and
"almost" in a payment system is a defect backlog you discover in production.

**Reviewer fatigue.** The obvious backstop is human review. But human review does
not scale linearly with volume, and it degrades: the twentieth near-identical diff
of the day gets less scrutiny than the first, and the defects that survive are
precisely the subtle ones a tired reviewer waves through. A process whose only
backstop degrades exactly as the volume that needs review climbs is not a backstop.

The through-line: none of these is the model failing to write C#. The model is
competent. What is missing is an independent, mechanical definition of correct —
governance around the model rather than faith in it.

## Pipeline shape

So the unit of work is not "convert a procedure." It is a chain of narrow stages
with hard boundaries, run by an orchestrator that enforces order and stops on the
first failure. Concretely: **analyse → generate implementation → generate tests →
review against encoded standards**.

Analyse reads the procedure and extracts intent, inputs, outputs, and contracts —
the shape of the result set, the parameters, the invariants it promises callers —
and is forbidden from writing any target code. Its output is a specification, and
keeping it code-free is the point: it is the artefact a human can check cheaply
before a line of .NET exists, and it lets you inspect whether the agent
*understood* the procedure separately from whether it *coded* it. Generate
implementation turns that specification into C#. Generate tests is deliberately
separate. Review checks the result against standards the pipeline holds
explicitly, not against a reviewer's mood.

The boundaries matter more than the stage list, and they are not drawn for
tidiness. Each one exists because something has to be **verified** as the work
crosses it. The analyse/generate boundary exists so the extracted contract can be
inspected independently of the implementation that claims to satisfy it. The
generate/test boundary exists so the two artefacts can be discussed separately —
which, as the next section argues, is the whole game. The orchestrator runs a
build-and-test gate after every stage that produced code, and if that gate fails
it halts and reports rather than carrying a broken conversion into the next
procedure. A stage that cannot be verified at its exit should not be a stage.

## Gate design

This is the spine, so it gets the most weight.

**Halt on first failure, not collect-all-errors.** The tempting design runs
everything, gathers every error, and hands the agent the full list to fix in one
pass. It comes from human workflows, where a batch of compiler errors is efficient
to fix together. Agents do not behave like that. Hand an agent five errors and it
will typically fix three, misunderstand the fourth, and — reaching for the fifth —
introduce a regression in code that was already correct. Errors interact; a batch
fix reasons about them jointly and reasons badly. Halting on the first failure
keeps each repair small and its blast radius contained. You fix one thing, re-run
the gate, and the gate tells you whether that one thing is now right and nothing
else broke. Slower per iteration, far faster to a correct end state.

**What counts as a gate.** A gate is a check with a binary, mechanical verdict:
the code compiles or it does not; the tests pass or they do not; the output
matches a known-good reference or it does not. "Looks correct" is not a gate. "The
reviewer was satisfied" is not a gate. Anything that routes through a judgement
call is a checkpoint — useful, but not a gate, because it cannot be trusted to
fail loudly and identically every time. It is the human-review failure mode
wearing a costume.

**The circularity trap.** Here is the failure that undoes most attempts at this,
and it is subtle enough that teams ship it without noticing. If the same agent
writes both the implementation and the tests, the tests are not evidence of
anything. The agent has written its own exam and then sat it. When its
understanding of the procedure is wrong, that wrong understanding flows into
*both* artefacts identically: the implementation computes the wrong thing, the
test asserts the wrong thing, the suite is green, and the green is meaningless.
Worse, it is confidently meaningless — a passing self-authored suite reads exactly
like a passing real one, and you cannot tell them apart by the pass rate. This is
the single most important thing to understand about verifying agentic output, and
it is exactly what a naive "and it even wrote tests!" pipeline gets wrong.

**The fix: differential testing against captured golden output.** The evidence has
to come from outside the agent. So *before any model touches the problem*, you run
the original stored procedure against seeded data and capture its result set as
JSON. That capture is the golden output. It is produced by the real system — SQL
Server executing the real T-SQL, no model in the loop — which is precisely what
makes it trustworthy, and it exists while the source of truth is still the source
of truth. Then you run the generated .NET against equivalent seeded data, capture
its result, and compare. A mismatch is a hard failure. The agent cannot argue with
it, cannot reinterpret it, and did not author it. The original procedure is the
oracle; the agent does not get to define correctness for its own work. The
agent-authored unit tests still earn their place — they document intent and catch
regressions cheaply as a fast inner loop — but they are never the thing that
clears the gate. The differential is.

Making the differential tractable is itself a design constraint, which is why the
conversion is **functional-parity-first**: convert one-to-one before optimizing or
redesigning anything. A faithful port produces a result set you can diff directly
against the original. Redesign the data model in the same step and the outputs no
longer line up — a mismatch could be a bug *or* an intended improvement, and the
gate can no longer tell you which. Optimization is deferred to an explicit later
phase, gated by its own differential against the parity version. The discipline
is: earn the right to change behaviour by first proving you preserved it.

**Where the differential actually catches things.** The mismatches cluster in type
and semantic edge cases, and these are the convincing part precisely because they
are the ones a human reviewer misses too. High-precision decimals truncated where
the two engines round differently. Timezone and UTC shifts where a value crosses a
boundary the .NET layer normalizes and the procedure did not. NULL represented one
way in T-SQL's three-valued logic and another in a document, so a filter that
matched in one silently does not in the other. Document-size limits a wide result
set trips. Identity and sequence generation, where a gapless counter, a
high-throughput allocator, and an opaque ID are three different decisions and the
old procedure quietly made one of them. The differential does not know these
categories exist. It reports that row 4,812 disagrees, and it is right.

**Bounded retries with a published cap.** When the gate fails, the agent retries,
and the retry count must be capped — with the cap published in the results. This
is not housekeeping; it is a correctness property of the metric. Uncapped retries
drive any pass rate to 100%: keep letting the agent try and eventually something
passes, whether or not it passes for the right reason. "97% of procedures
converted successfully" means nothing without "within a maximum of N attempts
each." The cap is what keeps the pass rate an honest measurement instead of a
foregone conclusion — and an agent that has not cleared the gate in N attempts is
not one attempt from success. It is stuck, and the honest move is to surface it
for a human rather than spend more budget rediscovering that.

## Governance as code

The coding standards, the architecture decisions, the conventions for how a
procedure becomes a service — these belong inside the agent's context, not in a
wiki nobody opens. In practice a wiki means they live nowhere, because nobody
reads it at the moment of writing code, least of all a model that was never
pointed at it. So the architecture decision records and the standards become
inputs to the work, not documentation about it.

What changes when a standard moves from a reviewer's memory to a checker is the
failure mode. The reviewer's version fails quietly and variably — sometimes
caught, sometimes not, depending on who and when. The checker's version is applied
uniformly, on every change, with no fatigue and no drift between reviewers,
because there is one reviewer and it is deterministic. Some checks can even
auto-fix against the encoded rule rather than merely flag it. The property the
whole migration exists to produce — the same standard, applied the same way, every
time — becomes structural instead of aspirational.

The cost is where the interesting work is. A standard written for a person can
lean on judgement: "prefer clear names," "handle money carefully." A standard
written for a machine cannot — you have to say that monetary values use this
decimal type at this precision, that rounding is this mode, and how the checker
recognizes a violation. The moment you try, you discover the rule was never as
precise as everyone assumed: half of what you called "standards" were actually
three unstated standards in a trench coat. That difficulty is not overhead. It is
the standard finally being pinned down, and the de-ambiguated version is better for
the humans too, because it no longer relies on everyone sharing the same unstated
judgement. In this kind of work the governance surface is naturally on the order
of a couple of dozen decision records and a few dozen coding standards. The real
labour of governance-as-code is not wiring up the checker. It is writing standards
precise enough to be checked — which turns out to be the act of actually deciding
what you meant.

## Distribution

Once the users of this tooling are your own teammates, the pipeline is a product,
and a product that ships to a team needs the boring machinery: versioning, an
update path, runbooks.

Skip it and the failure is quiet and corrosive. One engineer is running last
month's version of the conversion skill, another pulled a newer one, a third has
local tweaks. They are all "using the pipeline." But the encoded standards have
diverged, so the outputs are no longer produced against the same rules. Two
engineers convert two procedures, get two differently-shaped services, and neither
is wrong relative to the version they ran — so the results stop being comparable
across the team, and comparability was the entire point. The pass rate you report
now aggregates over an unknown mix of tool versions, which is no better than the
uncapped-retry problem, just harder to see. The uniform standard you paid for in
the governance work leaks away through version skew, and nothing announces it;
every individual run looks fine.

So the pipeline is versioned like software. Updates ship through a defined channel
— a private registry the whole team pulls from rather than files passed around —
and there is a runbook for what to do when a version changes under you, including
how to tell whether output from an old version needs regenerating. The mechanism
matters less than the invariant it protects: at any given time the team is on one
known version of the standards, and moving everyone forward is an operation someone
owns, not an accident of who updated when.

## Drift

The source does not hold still. Over a multi-month migration the procedures keep
being patched, and a conversion that was correct in month one may be a faithful
port of a procedure that no longer exists by month four. Ignore this and you ship
a modern service that faithfully reproduces last quarter's logic. This is the
constraint the demos never mention, and it forces machinery you would not build
for a one-shot job.

**Change detection.** Store a content hash or baseline for each source procedure
at the moment it was converted. Drift is then a mechanical comparison — current
hash versus baseline — and where nothing moved, there is no work.

**Selective regeneration.** When a procedure drifts, regenerate only what drifted
and what depends on it, not the whole tree. The stage boundaries pay off a second
time here: because analysis is a separate artefact, you can often tell whether a
change touched the contract or only the implementation, and scope the rework
accordingly.

**A mechanical definition of "still correct."** When a procedure changes its
golden output is stale, so you re-capture from the updated original and re-run the
differential. "Still correct" means "the baseline matches and the conversion still
agrees with a freshly captured golden output" — a query a machine runs unattended,
not "someone glanced at it and it seemed fine." Nothing softer holds up over months.

This implies an organizational shape, not just a technical one: a periodic
reconcile cadence that sweeps for drift on a schedule, and a dual-stream branching
discipline so the moving source and the in-flight conversion do not clobber each
other. And it rules out the tempting shortcut — "just rerun everything on a timer."
Rerunning everything is too expensive, because most procedures did not change and
you would pay full freight to rediscover that; and it is unsafe, because a needless
regeneration is a fresh roll of the dice on a conversion that was already certified
correct. Every regeneration is a risk. You want to take it exactly where the source
forced you to and nowhere else.

## Economics

Almost nobody writes about where the money goes in an agentic pipeline, and it is
not where people expect. Output tokens are nearly free by comparison; the cost is
dominated by context re-reads — the same schemas, contracts, and standards fed into
stage after stage, procedure after procedure, and re-read on every retry. An agent
that reads a large context, fails the gate, and retries has paid for that context
twice; three retries, four times. The shape of the curve is, roughly, *input tokens
re-read × attempts* — the output barely registers on it.

The counterintuitive consequence: **the cost lever is what each stage is allowed to
read, not how much it writes.** Teams reach instinctively for "make the output
shorter." Wrong knob. So, three moves in order of impact. **Trim per-stage inputs**
to the minimum that still lets the stage verify its own output — the implementation
stage needs the analysis and the standards, not the entire source tree; the review
stage does not need everything analyse read. **Cache the stable prefix** so the
unchanging parts of the context — the standards, the conventions — are paid for
once and reused, not re-billed on every attempt. **Cap the retries**, because an
uncapped loop is an uncapped invoice as well as a dishonest metric; the cap earns
its keep twice.

The discipline most teams skip is measuring cost per unit at all. Without a
cost-per-procedure number the pipeline's price is a surprise that arrives monthly
and attaches to nothing you can change. With it, cost becomes an engineering
quantity: you can see which stage is expensive, which procedures are retry-magnets,
and whether a context change actually helped. And this closes back onto governance
— a stage that knows precisely what it must produce, because the standard is
explicit, reads less to get there. Encoded standards are not only a correctness
mechanism. They bound cost, because precision is cheaper than searching.

## What I would do differently

Three honest ones.

**I underinvested in golden-output capture at the start.** It is unglamorous
plumbing and tempting to defer, so the first conversions leaned on agent-authored
tests — exactly the circular trap above. The differential is only as good as the
oracle it compares against and the data it runs both sides over; the boundary
decimals, the NULLs, the timezone crossings only get caught if the seed data
exercises them. I treated seeding and capture as setup, and they were actually part
of the gate. The capture harness should have been the first thing built, before a
single conversion.

**I wrote the first standards for humans and then tried to teach a checker to
enforce them, which was backwards.** They were full of gaps a person fills with
judgement and a machine cannot see, and the vagueness propagated downstream where
the differential caught the symptom far from the cause. Writing them to be
machine-enforceable from the start would have surfaced the real disagreements
earlier, while they were cheap to settle — and tightened the analyse contract at
the same time, moving failures closer to their origin.

**I under-planned distribution, and treated drift as an afterthought.** I got the
pipeline correct before I got it shippable, and for a stretch the team ran
different vintages of it without anyone deciding to; the governance was sound and
version skew undid part of it anyway. The change-detection and reconcile machinery,
likewise, got bolted on once the source visibly moved under us. Both belong in the
definition of "done" from day one — along with publishing the retry cap and the
attempt distribution rather than adding them when someone asks how the pass rate
was computed. The number was honest, but it did not *look* honest until the
denominator was visible, and the credibility of the whole system rests on the gate.
A gate you cannot audit is, to everyone outside your head, indistinguishable from
no gate at all.

The clever part — an agent that writes a plausible service class — was working
early and was never the risk. The risk was always time, money, and proof: encoding
judgement so the same standard applies every time without a human in each loop,
keeping the team pointed at the same copy of that judgement while the ground moves,
and being able to show a stranger *why* the output is correct rather than asking
them to take it on faith. That is the work.
