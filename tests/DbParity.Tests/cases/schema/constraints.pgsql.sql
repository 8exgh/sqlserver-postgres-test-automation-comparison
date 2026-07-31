SELECT n.nspname                                            AS SchemaName,
       c.relname                                            AS TableName,
       con.conname                                          AS ConstraintName,
       -- 'c1' / 'c2' rather than 'c' / 'f' so the two engines sort identically:
       -- check before foreign key, matching the SQL Server side's labels.
       CASE con.contype WHEN 'p' THEN 'p'
                        WHEN 'u' THEN 'u'
                        WHEN 'f' THEN 'c2'
                        ELSE 'c1' END                       AS Kind,
       COALESCE((SELECT string_agg(a.attname, ',' ORDER BY k.ord)
                 FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
                 JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
                 WHERE con.contype <> 'c'), '')             AS KeyColumns,
       CASE WHEN con.contype = 'f' THEN
           (SELECT rn.nspname || '.' || rc.relname || '(' ||
                   string_agg(ra.attname, ',' ORDER BY k.ord) || ')'
            FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
            JOIN pg_class rc     ON rc.oid = con.confrelid
            JOIN pg_namespace rn ON rn.oid = rc.relnamespace
            JOIN pg_attribute ra ON ra.attrelid = con.confrelid AND ra.attnum = k.attnum
            GROUP BY rn.nspname, rc.relname)
       ELSE '' END                                          AS RefersTo
FROM pg_constraint con
JOIN pg_class c     ON c.oid = con.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE con.contype IN ('p', 'u', 'f', 'c')
  AND c.relkind = 'r'
  AND n.nspname IN ('ref', 'client', 'tax', 'acct', 'payroll', 'audit')
ORDER BY SchemaName, TableName, Kind, ConstraintName;
