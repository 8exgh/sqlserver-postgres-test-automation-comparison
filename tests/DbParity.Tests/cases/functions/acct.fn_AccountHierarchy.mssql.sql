-- @name      acct.fn_AccountHierarchy · recursive CTE with depth and path
-- @category  function-accounting
--
-- WITH RECURSIVE on PostgreSQL, a plain recursive CTE on SQL Server. Depth
-- and the materialized path are exactly what a mistranslated anchor or
-- recursive term gets wrong.
SELECT c.ClientId, h.AccountId, h.ParentAccountId, h.AccountNumber, h.AccountName,
       h.AccountTypeCode, h.Depth, h.NamePath, h.SortPath
FROM client.Client c
     CROSS APPLY acct.fn_AccountHierarchy(c.ClientId, NULL) h
ORDER BY c.ClientId, h.SortPath, h.AccountId;
