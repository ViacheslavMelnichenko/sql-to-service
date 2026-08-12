# Corpus source

The corpus is the public, MIT-licensed **WideWorldImporters** sample database
published by Microsoft. Using a well-known public sample is deliberate: anyone
can recognize the schema at a glance, verify our procedure extracts against the
upstream source, and reproduce the whole thing without any private data.

## The pin

| Field | Value |
| --- | --- |
| Database | WideWorldImporters — **Standard** edition backup |
| File | `WideWorldImporters-Standard.bak` |
| Upstream | Microsoft `sql-server-samples` GitHub release `wide-world-importers-v1.0` |
| License | MIT |
| SHA-256 | `066279a8cd28c8d85cbd8215ea71a5d672b420cfbc19756b635c27bd8027dada` |

> **Why Standard, not Full.** The **Full** backup uses in-memory OLTP filegroups
> and columnstore features that fail to restore inside a Linux SQL Server
> container — the exact environment `docker compose` gives you. The
> **Standard** backup restores cleanly on `mcr.microsoft.com/mssql/server` and
> carries the same schema and the same stored procedures we convert. Choosing it
> is what keeps "reproduce from a clean clone" honest.

## What we take from it

Only the **stored procedures** in two schemas (see `SELECTION.md`) and a
**branch-covering slice** of the seed data needed to exercise them (see
`docs/adr/0002-dataset-sizing.md`). We do **not** commit the `.bak` — it is
downloaded and SHA-verified by `corpus/restore.sh`. We commit only:

- the extracted procedure text (`corpus/procs/*.sql`),
- the seed we derive (`corpus/seed/*`),
- the golden output we capture (`corpus/golden/*.json`).

## Integrity

`corpus/restore.sh` downloads the pinned `.bak`, checks its SHA-256 against the
value recorded above, and **fails loudly** on mismatch — a changed upstream file
is a supply-chain event, not something to restore silently. The SHA is filled in
once, from the actual downloaded artifact, and never edited to match a new
download without a note in `CHANGELOG.md`.

## Introduced specifics (overrule cheaply)

- **Standard over Full** — chosen for Linux-container restore compatibility; this
  is a real constraint, not a preference.
- The SHA-256 above was recorded from the actual download
  (`066279a8…027dada`, 121 MB) on 2026-08-07 and is now the pin `restore.sh`
  enforces. The release tag is `wide-world-importers-v1.0`.
