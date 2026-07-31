-- @name      audit.vw_RecentChanges · full contents
-- @category  view
-- @sort      client
--
-- OPENJSON shredding on SQL Server, jsonb functions here -- the other view
-- SCT could not convert. Ordered by column name because the shredded row order
-- is not otherwise defined.
SELECT *
FROM audit.vw_RecentChanges
ORDER BY ChangeLogId, ColumnName;
