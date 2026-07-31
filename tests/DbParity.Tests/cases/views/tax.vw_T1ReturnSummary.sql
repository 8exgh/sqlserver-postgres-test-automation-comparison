-- @name      tax.vw_T1ReturnSummary · full contents
-- @category  view
--
-- The widest behavioural comparison in the suite: it recomputes tax live and
-- exposes the variance against the stored assessment, so every tax function and
-- the assessment data have to agree at once.
SELECT *
FROM tax.vw_T1ReturnSummary
ORDER BY T1ReturnId;
