-- @name      schema · indexes, including covering and filtered
-- @category  schema
--
-- Compares name, uniqueness, key columns, INCLUDE columns and whether the index
-- is filtered. The filter PREDICATE is not compared -- SQL Server renders it as
-- ([IsActive]=(1)) and PostgreSQL as (isactive = 1::numeric), which is the same
-- condition in two dialects. Whether an index is partial at all is the part that
-- would break a query plan if the port lost it, and that is compared.
--
-- Restricted to indexes on tables. SQL Server's one indexed view and the
-- materialized view that replaces it are covered by schema/inventory instead,
-- since they are different kinds of object.
SELECT LOWER(s.name)                                     AS SchemaName,
       LOWER(t.name)                                     AS TableName,
       LOWER(i.name)                                     AS IndexName,
       CASE WHEN i.is_unique = 1 THEN 1 ELSE 0 END       AS IsUnique,
       (SELECT STRING_AGG(LOWER(CONVERT(varchar(128), c.name)), ',')
                   WITHIN GROUP (ORDER BY ic.key_ordinal)
        FROM sys.index_columns ic
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
          AND ic.is_included_column = 0)                 AS KeyColumns,
       COALESCE((SELECT STRING_AGG(LOWER(CONVERT(varchar(128), c.name)), ',')
                     WITHIN GROUP (ORDER BY ic.index_column_id)
                 FROM sys.index_columns ic
                 JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
                   AND ic.is_included_column = 1), '')   AS IncludedColumns,
       CASE WHEN i.has_filter = 1 THEN 1 ELSE 0 END      AS IsPartial
FROM sys.indexes i
JOIN sys.tables t  ON t.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE i.type > 0 AND i.is_hypothetical = 0 AND i.name IS NOT NULL
ORDER BY SchemaName, TableName, IndexName;
