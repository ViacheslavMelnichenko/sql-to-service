# Corpus selection

The criterion is written **before** the outcome is known, and every procedure
it selects is kept — no dropping the ones that turn out hard. The failures are
the most credible part of the results.

## Source

Microsoft's public `WideWorldImporters` sample database
(`microsoft/sql-server-samples`, MIT). Nothing here comes from any client
engagement.

## Criterion

<!-- TODO: state the exact rule, e.g. "every procedure in schema X that returns
a result set and takes fewer than N parameters", then list what it selected.
Target size: 12-20 procedures. Not more. -->

## Deterministic-output caveat

<!-- TODO: list procedures excluded (or inputs frozen) because output depends on
GETDATE(), NEWID() or ambient state, and why. -->

## Selected

<!-- TODO: the list the criterion produced. -->
