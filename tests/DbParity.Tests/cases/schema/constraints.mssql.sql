-- @name      schema · primary, unique, foreign-key and check constraints
-- @category  schema
-- @divergence-key schemaname, tablename, constraintname
--
-- Compared by name, kind and key columns. Check-constraint EXPRESSIONS are not
-- compared: the two dialects render them differently by definition, so the text
-- would always differ and say nothing. What matters here is that every named
-- constraint exists on both sides and, where it has key columns, covers the same
-- ones in the same order.
--
-- Constraint names are lowercased on both sides; SQL Server declares them in
-- mixed case (FK_TaxBracket_Jurisdiction) and the port in lower.
SELECT SchemaName, TableName, ConstraintName, Kind, KeyColumns, RefersTo
FROM (
    -- primary keys and unique constraints
    SELECT LOWER(s.name)                                        AS SchemaName,
           LOWER(t.name)                                        AS TableName,
           LOWER(kc.name)                                       AS ConstraintName,
           CASE kc.type WHEN 'PK' THEN 'p' ELSE 'u' END COLLATE DATABASE_DEFAULT AS Kind,
           STRING_AGG(LOWER(CONVERT(varchar(128), col.name)), ',')
               WITHIN GROUP (ORDER BY ic.key_ordinal)           AS KeyColumns,
           CONVERT(varchar(300), '')                            AS RefersTo
    FROM sys.key_constraints kc
    JOIN sys.tables t        ON t.object_id = kc.parent_object_id
    JOIN sys.schemas s       ON s.schema_id = t.schema_id
    JOIN sys.index_columns ic ON ic.object_id = kc.parent_object_id
                             AND ic.index_id = kc.unique_index_id
    JOIN sys.columns col     ON col.object_id = ic.object_id
                            AND col.column_id = ic.column_id
    GROUP BY s.name, t.name, kc.name, kc.type

    UNION ALL

    -- foreign keys, with the target they point at
    SELECT LOWER(s.name),
           LOWER(t.name),
           LOWER(fk.name),
           'c2' COLLATE DATABASE_DEFAULT,
           STRING_AGG(LOWER(CONVERT(varchar(128), pc.name)), ',')
               WITHIN GROUP (ORDER BY fkc.constraint_column_id),
           CONVERT(varchar(300),
               LOWER(rs.name) + '.' + LOWER(CONVERT(varchar(128), rt.name)) + '(' +
               STRING_AGG(LOWER(CONVERT(varchar(128), rc.name)), ',')
                   WITHIN GROUP (ORDER BY fkc.constraint_column_id) + ')')
    FROM sys.foreign_keys fk
    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    JOIN sys.tables t   ON t.object_id = fk.parent_object_id
    JOIN sys.schemas s  ON s.schema_id = t.schema_id
    JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id
                       AND pc.column_id = fkc.parent_column_id
    JOIN sys.tables rt  ON rt.object_id = fk.referenced_object_id
    JOIN sys.schemas rs ON rs.schema_id = rt.schema_id
    JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id
                       AND rc.column_id = fkc.referenced_column_id
    GROUP BY s.name, t.name, fk.name, rs.name, rt.name

    UNION ALL

    -- check constraints: name only, for the reason above
    SELECT LOWER(s.name),
           LOWER(t.name),
           LOWER(cc.name),
           'c1' COLLATE DATABASE_DEFAULT,
           CONVERT(varchar(300), ''),
           CONVERT(varchar(300), '')
    FROM sys.check_constraints cc
    JOIN sys.tables t  ON t.object_id = cc.parent_object_id
    JOIN sys.schemas s ON s.schema_id = t.schema_id
) x
ORDER BY SchemaName, TableName, Kind, ConstraintName;
