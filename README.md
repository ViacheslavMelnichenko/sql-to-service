# sql-to-service

An agentic pipeline that converts T-SQL stored procedures into a .NET service
layer, gated by differential testing against the original procedures' output —
and an eval harness that reports how often it works and what it costs.

> **Status: scaffolding.** The corpus, pipeline and results below are not
> populated yet. This README documents the target shape; numbers are
> placeholders until the first run lands.

## Results (run-XXX, N procedures from WideWorldImporters)

| Metric | Value |
| --- | --- |
| Cleared all gates unedited | — / — |
| Median cost per procedure | $— |
| Median attempts | — |

<!-- Cost-delta sentence goes here once run-001 and run-002 exist. -->
[How these numbers were produced](evals/METHOD.md) ·
[Failure taxonomy](evals/results/summary.md)

## Reproduce

```sh
docker compose up -d          # SQL Server with the seeded corpus
./gates/verify.sh             # build + unit + differential on committed output
ANTHROPIC_API_KEY=... ./pipeline/run.py --all   # regenerate (costs money)
```

## What this is not

Not a migration tool. The corpus is a small set of procedures from a public
sample database, chosen by [a written criterion](corpus/SELECTION.md) and not
cherry-picked. Nothing here comes from any client engagement.
