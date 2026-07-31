-- @name      acct.vw_GeneralLedger · full contents
-- @category  view
--
-- Running balance via SUM() OVER. The window frame is the interesting part:
-- a port that omits ROWS BETWEEN gets a different running total.
SELECT *
FROM acct.vw_GeneralLedger
ORDER BY ClientId, FiscalYearId, JournalEntryId, JournalLineId;
