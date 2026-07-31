-- @name      acct.vw_InvoiceAging · full contents
-- @category  view-temporal
--
-- Built with PIVOT on SQL Server and conditional aggregation here -- one of
-- the two views AWS SCT could not convert at all (db/README.md). Also "as at
-- today", hence the temporal category.
SELECT *
FROM acct.vw_InvoiceAging
ORDER BY ClientId;
