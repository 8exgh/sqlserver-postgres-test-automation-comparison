-- @name      schema · object inventory
-- @category  schema
-- @sort      client
--
-- Only the counts that must be one-to-one. Two kinds are deliberately absent
-- because they legitimately differ, and forcing them to match would mean either
-- a false failure or an allowlist entry that hides real drift:
--
--   functions  SQL Server has 20; PostgreSQL has those plus a trigger function
--              for every trigger, because PL/pgSQL triggers cannot carry their
--              body inline the way T-SQL triggers do.
--   triggers   4 on SQL Server, 8 here -- the port adds client.tr_Client_BIU to
--              emulate ROWVERSION, which SQL Server gets from the engine.
--
-- Each engine's own 099_verify.sql already asserts its exact counts, so those
-- two are covered there rather than being fudged into agreement here.
SELECT 'tables' AS ObjectKind, COUNT(*) AS Total FROM sys.tables
UNION ALL
SELECT 'views', COUNT(*) FROM sys.views
UNION ALL
SELECT 'procedures', COUNT(*) FROM sys.objects WHERE type = 'P'
UNION ALL
SELECT 'foreign keys', COUNT(*) FROM sys.foreign_keys
UNION ALL
SELECT 'generated columns', COUNT(*)
FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id
WHERE c.is_computed = 1
UNION ALL
SELECT 'partial indexes', COUNT(*)
FROM sys.indexes i JOIN sys.tables t ON t.object_id = i.object_id
WHERE i.has_filter = 1;
