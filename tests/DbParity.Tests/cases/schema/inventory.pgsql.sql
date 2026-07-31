SELECT 'tables' AS ObjectKind, COUNT(*) AS Total
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r' AND n.nspname IN ('ref', 'client', 'tax', 'acct', 'payroll', 'audit')
UNION ALL
-- The indexed view on SQL Server is a materialized view here, so both kinds count.
SELECT 'views', COUNT(*)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('v', 'm')
  AND n.nspname IN ('ref', 'client', 'tax', 'acct', 'payroll', 'audit', 'util')
UNION ALL
SELECT 'procedures', COUNT(*)
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.prokind = 'p' AND n.nspname IN ('ref', 'client', 'tax', 'acct', 'payroll', 'audit', 'util')
UNION ALL
SELECT 'foreign keys', COUNT(*)
FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE con.contype = 'f' AND n.nspname IN ('ref', 'client', 'tax', 'acct', 'payroll', 'audit')
UNION ALL
SELECT 'generated columns', COUNT(*)
FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE a.attgenerated = 's' AND c.relkind = 'r'
  AND n.nspname IN ('ref', 'client', 'tax', 'acct', 'payroll', 'audit')
UNION ALL
SELECT 'partial indexes', COUNT(*)
FROM pg_index ix JOIN pg_class c ON c.oid = ix.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE ix.indpred IS NOT NULL AND c.relkind = 'r'
  AND n.nspname IN ('ref', 'client', 'tax', 'acct', 'payroll', 'audit');
