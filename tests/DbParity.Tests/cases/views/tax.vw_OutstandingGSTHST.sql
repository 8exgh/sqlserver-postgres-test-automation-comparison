-- @name      tax.vw_OutstandingGSTHST · full contents
-- @category  view-temporal
--
-- DaysPastDue is relative to today, so this is stable across engines at one
-- instant but not across days. Both sides are read in the same test, seconds
-- apart; a failure here at midnight is the clock, not the port.
SELECT *
FROM tax.vw_OutstandingGSTHST
ORDER BY GSTHSTReturnId;
