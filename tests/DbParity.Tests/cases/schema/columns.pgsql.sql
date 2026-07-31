SELECT n.nspname                                        AS SchemaName,
       c.relname                                        AS TableName,
       a.attname                                        AS ColumnName,
       ROW_NUMBER() OVER (PARTITION BY n.nspname, c.relname
                          ORDER BY a.attnum)            AS Ordinal,
       format_type(a.atttypid, a.atttypmod)             AS DataType,
       CASE WHEN a.attnotnull THEN 0 ELSE 1 END         AS IsNullable,
       CASE WHEN a.attgenerated = 's' THEN 1 ELSE 0 END AS IsGenerated,
       CASE WHEN a.attidentity IN ('a', 'd') THEN 1 ELSE 0 END AS IsIdentity
FROM pg_attribute a
JOIN pg_class c     ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname IN ('ref', 'client', 'tax', 'acct', 'payroll', 'audit')
  AND a.attnum > 0
  AND NOT a.attisdropped
ORDER BY SchemaName, TableName, Ordinal;
