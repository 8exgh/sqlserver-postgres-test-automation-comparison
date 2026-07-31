-- @name      acct.fn_InvoiceAging · outstanding receivables, bucketed
-- @category  function-accounting
--
-- Takes a single date, so no lateral join is needed and the SQL is portable.
-- Fixed dates rather than "today", so the buckets are deterministic.
SELECT *
FROM acct.fn_InvoiceAging(CAST('2025-06-30' AS DATE))
ORDER BY InvoiceId;
