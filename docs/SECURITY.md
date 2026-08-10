# Security notes

This is a demonstration repository over public sample data, so nothing here is a
real secret and nothing here processes real customer data. This document exists to
answer the security questions a client review *would* ask, and to be explicit about
which answers are "done in the demo" versus "a prerequisite before any real
engagement." See [`DEPLOYABILITY.md`](DEPLOYABILITY.md) for the deployment framing;
this page is the concrete handling.

## Secret handling

**Today (demo):** `corpus/seed/seed-mongo.sh` sources `.env` and passes
`MSSQL_SA_PASSWORD` to `sqlcmd` via `-P` on the command line. CI writes a
runner-only throwaway password into `.env` and tears the engine down with the job
(`.github/workflows/verify.yml`). Acceptable for a disposable dev engine; **not**
acceptable against a real database.

**Two specific weaknesses, named so they aren't discovered:**

- **Secret on argv.** A password passed as `-P "$SECRET"` is visible in the host
  process table (`ps`, `docker inspect`) to anything sharing that host, and leaks
  into shell history and logs. It should be delivered to the tool as an environment
  variable the tool *reads*, or via the client's native credential channel, never as
  a command-line argument.
- **`.env` on disk.** Fine for a torn-down dev container; wrong for a production
  credential.

**Client-grade handling (prerequisite, not built here):**

- Fetch credentials at run time from a secrets manager — HashiCorp Vault, AWS/GCP
  Secrets Manager, or the platform's native store — rather than committing or
  persisting them.
- Use a **least-privilege, short-lived DB principal** for the capture/seed path, not
  the `sa` account this demo uses for convenience. The capture only needs read on the
  base tables and execute on the procs in scope.
- Keep `.env` for **local, disposable engines only**. It is `.gitignore`d; verify it
  is never committed.

## Data handling / PII

The demo corpus is the public MIT-licensed WideWorldImporters sample — **no real
data is present, and none should ever be.** The method's seed path
(`export-relational.py --all-tables` → `corpus/seed/relational.json`, committed)
dumps whole base tables; on the demo those rows are fictional, but applied to a real
database it would place production data in a git history.

**Prerequisite before any engagement touching real tables:** a masking / synthesis
step that derives the seed's *shape and branch-covering cases* from the real schema
and then **synthesises** the rows — real customer values never enter the corpus. The
golden is captured over the synthetic seed, so non-circularity is preserved (the
oracle still predates the model; it simply reads synthetic input). This is scoped in
[`DEPLOYABILITY.md`](DEPLOYABILITY.md) §(b) and is **not** built in this demo.

## Supply chain

- **Corpus provenance is pinned.** The source is recorded with a URL and SHA in
  [`../corpus/SOURCE.md`](../corpus/SOURCE.md), so the input the golden was captured
  from is fixed and verifiable, not a moving upstream.
- **CI Actions are pinned to major versions** and run with `permissions: contents:
  read` (`.github/workflows/verify.yml`) — the gate job has no write scope on the
  repo.
- **Dependencies.** The .NET services use the MongoDB driver; the seed/gate tooling
  uses Python stdlib plus `pymongo`. NuGet advisories (`NU1902`/`NU1903`) surface at
  build time — the differential deliberately runs the *compiled binary*, never
  `dotnet run`, partly so advisory text on stdout can never corrupt the JSON the gate
  parses (`gates/differential.sh`).
- **The model is not in the trusted-computing base for correctness.** This is the
  point of the whole repo: the generator can be compromised, wrong, or swapped, and
  the deterministic gate — captured before the model ran, run with no model in the
  loop — still has the authority to reject a bad conversion (ADR-0001). A supply-chain
  compromise of the *generator* is caught by the *gate*, not trusted through it.

## Threat-model boundary (what this demo does and does not claim)

- **In scope, demonstrated:** the correctness gate cannot be fooled by a colluding or
  compromised generator (non-circular oracle + mutation-proven teeth).
- **In scope, named-but-not-built:** PII synthesis, secrets-manager integration,
  least-privilege DB principals — prerequisites for a real engagement, scoped in
  `DEPLOYABILITY.md`.
- **Out of scope:** hardening the model-serving path itself, network segmentation of
  the engines, and audit logging of agent actions — these belong to the deploying
  organisation's platform, not this artifact.
