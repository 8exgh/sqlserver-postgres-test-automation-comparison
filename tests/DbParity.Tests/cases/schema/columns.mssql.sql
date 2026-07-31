-- @name      schema · every column, with the declared type mapping applied
-- @category  schema
--
-- Divergent by nature: this reads each engine's own catalog and projects it into
-- one shape. The SQL Server side renders each type as the PostgreSQL type the
-- port is supposed to use, so an unmapped or wrongly-mapped type shows up as a
-- cell difference naming the exact column.
--
-- The mapping is closed: anything not listed comes out as 'UNMAPPED:<type>' and
-- fails loudly rather than being quietly skipped.
--
--   int -> integer            tinyint    -> smallint   (widened; no PG analogue)
--   bit -> numeric(1,0)       nvarchar   -> varchar    (PG is Unicode throughout)
--   decimal -> numeric        datetime2  -> timestamp
--   char -> character         rowversion -> bigint     (emulated by a trigger)
--   nvarchar(max) -> jsonb    sysname    -> varchar(128)
SELECT LOWER(s.name)                                    AS SchemaName,
       LOWER(t.name)                                    AS TableName,
       LOWER(c.name)                                    AS ColumnName,
       ROW_NUMBER() OVER (PARTITION BY s.name, t.name
                          ORDER BY c.column_id)         AS Ordinal,
       CASE CONVERT(varchar(60), ty.name) COLLATE DATABASE_DEFAULT
           WHEN 'int'       THEN 'integer'
           WHEN 'smallint'  THEN 'smallint'
           WHEN 'tinyint'   THEN 'smallint'
           WHEN 'bigint'    THEN 'bigint'
           WHEN 'bit'       THEN 'numeric(1,0)'
           WHEN 'date'      THEN 'date'
           WHEN 'timestamp' THEN 'bigint'
           WHEN 'sysname'   THEN 'character varying(128)'
           WHEN 'decimal'
               THEN 'numeric(' + CAST(c.precision AS varchar(10)) + ','
                               + CAST(c.scale AS varchar(10)) + ')'
           WHEN 'datetime2'
               THEN 'timestamp(' + CAST(c.scale AS varchar(10)) + ') without time zone'
           WHEN 'char'
               THEN 'character(' + CAST(c.max_length AS varchar(10)) + ')'
           WHEN 'nvarchar'
               THEN CASE WHEN c.max_length = -1
                         THEN 'jsonb'
                         ELSE 'character varying(' + CAST(c.max_length / 2 AS varchar(10)) + ')'
                    END
           ELSE 'UNMAPPED:' + CONVERT(varchar(60), ty.name) COLLATE DATABASE_DEFAULT
       END                                              AS DataType,
       CASE WHEN c.is_nullable = 1 THEN 1 ELSE 0 END    AS IsNullable,
       CASE WHEN c.is_computed = 1 THEN 1 ELSE 0 END    AS IsGenerated,
       CASE WHEN c.is_identity = 1 THEN 1 ELSE 0 END    AS IsIdentity
FROM sys.columns c
JOIN sys.tables t   ON t.object_id = c.object_id
JOIN sys.schemas s  ON s.schema_id = t.schema_id
JOIN sys.types ty   ON ty.user_type_id = c.user_type_id
ORDER BY SchemaName, TableName, Ordinal;
