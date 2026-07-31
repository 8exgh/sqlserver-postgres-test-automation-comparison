SELECT n.nspname                                          AS SchemaName,
       c.relname                                          AS TableName,
       i.relname                                          AS IndexName,
       CASE WHEN ix.indisunique THEN 1 ELSE 0 END         AS IsUnique,
       (SELECT string_agg(pg_get_indexdef(ix.indexrelid, k, true), ',' ORDER BY k)
        FROM generate_series(1, ix.indnkeyatts) AS k)     AS KeyColumns,
       COALESCE((SELECT string_agg(pg_get_indexdef(ix.indexrelid, k, true), ',' ORDER BY k)
                 FROM generate_series(ix.indnkeyatts + 1, ix.indnatts) AS k), '')
                                                          AS IncludedColumns,
       CASE WHEN ix.indpred IS NOT NULL THEN 1 ELSE 0 END AS IsPartial
FROM pg_index ix
JOIN pg_class i     ON i.oid = ix.indexrelid
JOIN pg_class c     ON c.oid = ix.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname IN ('ref', 'client', 'tax', 'acct', 'payroll', 'audit')
ORDER BY SchemaName, TableName, IndexName;
