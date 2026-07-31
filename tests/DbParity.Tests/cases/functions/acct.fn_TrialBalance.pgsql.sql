SELECT f.FiscalYearId, t.AccountId, t.AccountNumber, t.AccountName, t.AccountTypeCode,
       t.NormalBalance, t.TotalDebits, t.TotalCredits, t.Balance, t.IsTotalRow
FROM acct.FiscalYear f
     CROSS JOIN LATERAL acct.fn_TrialBalance(f.ClientId, f.FiscalYearId, f.EndDate) t
ORDER BY f.FiscalYearId, t.IsTotalRow, t.AccountNumber;
