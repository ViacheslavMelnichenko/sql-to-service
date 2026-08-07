-- corpus/select.sql — the mechanical corpus screen.
--
-- Runs against the restored WideWorldImporters and emits, for every procedure in
-- the two candidate schemas, the facts the selection criterion (corpus/SELECTION.md)
-- turns into a verdict. It is committed and re-runnable so a reviewer can confirm we
-- did not hand-pick: the SAME query that produced the enumeration table is here to
-- run again.
--
--   docker compose exec -T mssql /opt/mssql-tools18/bin/sqlcmd \
--     -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -No -d WideWorldImporters \
--     -i /corpus/select.sql
--
-- WHY dm_sql_referenced_entities and not a substring scan of the body:
-- criterion 1 turns on "does it write a BASE table" (persistent state that could
-- leak between cases) vs "does it write a #temp table" (dropped at proc exit,
-- cannot leak). A `LIKE '%INSERT%'` scan cannot tell the two apart, AND it
-- misreads aliases — `UPDATE cc ... FROM #CustomerChanges AS cc` is a #temp write
-- that a naive `UPDATE [^#]` pattern flags as a base write. So we ask SQL Server's
-- OWN dependency engine instead: `is_updated = 1` means the procedure writes that
-- referenced base object. #temp tables are not base objects, so they never appear
-- with is_updated. This is the authoritative signal; the body LIKEs below are kept
-- ONLY as descriptive shape hints (cursor / temporal / geography), never verdicts.

SET NOCOUNT ON;

;WITH procs AS (
    SELECT p.object_id,
           s.name AS schema_name,
           p.name AS proc_name,
           s.name + '.' + p.name AS full_name,
           OBJECT_DEFINITION(p.object_id) AS body,
           (SELECT COUNT(*) FROM sys.parameters pa
            WHERE pa.object_id = p.object_id AND pa.is_output = 0) AS param_count
    FROM sys.procedures p
    JOIN sys.schemas s ON s.schema_id = p.schema_id
    WHERE s.name IN ('Website', 'Integration')
),
deps AS (
    SELECT pr.object_id,
           MAX(CASE WHEN r.is_updated = 1 THEN 1 ELSE 0 END) AS writes_base_table
    FROM procs pr
    OUTER APPLY sys.dm_sql_referenced_entities(pr.full_name, 'OBJECT') r
    GROUP BY pr.object_id
)
SELECT
    pr.full_name                  AS [procedure],
    pr.param_count                AS params,
    d.writes_base_table           AS writes_base_table,   -- authoritative (criterion 1)
    -- Determinism red flags (criterion 3):
    CASE WHEN pr.body LIKE '%NEWID(%' OR pr.body LIKE '%GETDATE(%'
           OR pr.body LIKE '%SYSDATETIME(%' OR pr.body LIKE '%SYSUTCDATETIME(%'
         THEN 1 ELSE 0 END        AS nondeterministic,
    -- Descriptive shape hints only (context for the enumeration notes, not verdicts):
    CASE WHEN pr.body LIKE '%CURSOR%' THEN 1 ELSE 0 END          AS uses_cursor,
    CASE WHEN pr.body LIKE '%FOR SYSTEM_TIME%' THEN 1 ELSE 0 END AS temporal,
    CASE WHEN pr.body LIKE '%geography%' THEN 1 ELSE 0 END       AS has_geography,
    LEN(pr.body)                  AS body_len
FROM procs pr
JOIN deps d ON d.object_id = pr.object_id
ORDER BY d.writes_base_table, nondeterministic, pr.schema_name, pr.proc_name;
