# Method

How the numbers in the results table were produced.

## `cleared_unedited` — the headline metric

A procedure counts as `cleared_unedited` when it **passed the build, unit and
differential gates with zero human edits, within the retry cap.** Nothing else
counts. This mirrors the one metric the whole artifact exists to make checkable.

<!-- TODO: fill in once the harness exists.
- retry cap and why it is published
- what each gate checks
- how cost (tokens in/out, cache reads) is accounted per attempt
- deterministic-output handling (frozen GETDATE()/NEWID(), excluded procs)
-->
