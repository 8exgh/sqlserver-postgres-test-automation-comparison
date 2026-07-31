-- @name      acct.fn_TrialBalance · per-account totals plus the total row
-- @category  function-accounting
--
-- A multi-statement table-valued function on SQL Server, plpgsql here. The
-- IsTotalRow flag matters: the total row is appended after the cursor loop, so
-- a port that returns it in a different position is a real difference.
SELECT f.FiscalYearId, t.AccountId, t.AccountNumber, t.AccountName, t.AccountTypeCode,
       t.NormalBalance, t.TotalDebits, t.TotalCredits, t.Balance, t.IsTotalRow
FROM acct.FiscalYear f
     CROSS APPLY acct.fn_TrialBalance(f.ClientId, f.FiscalYearId, f.EndDate) t
ORDER BY f.FiscalYearId, t.IsTotalRow, t.AccountNumber;
