-- @name      acct.vw_FiscalYearRevenue · full contents
-- @category  view
--
-- An indexed view on SQL Server, a materialized view here. PostgreSQL does
-- not maintain it automatically, so the replicator refreshes it after loading;
-- if that step were missed this case would fail with empty or stale rows.
SELECT *
FROM acct.vw_FiscalYearRevenue
ORDER BY ClientId, FiscalYearId, AccountTypeCode;
