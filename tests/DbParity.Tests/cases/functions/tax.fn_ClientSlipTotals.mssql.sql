-- @name      tax.fn_ClientSlipTotals · slip boxes rolled into T1 lines
-- @category  function-tax
--
-- Every client and every seeded year, so a box-to-line mapping dropped in the
-- port shows up as a zero where the source has an amount.
SELECT c.ClientId, y.TaxYear, t.EmploymentIncome, t.InvestmentIncome,
       t.SelfEmploymentIncome, t.PensionIncome, t.OtherIncome, t.Deductions,
       t.TaxWithheld, t.CPPContributions, t.EIPremiums, t.SlipCount
FROM client.Client c
     CROSS JOIN ref.TaxYear y
     CROSS APPLY tax.fn_ClientSlipTotals(c.ClientId, y.TaxYear) t
ORDER BY c.ClientId, y.TaxYear;
