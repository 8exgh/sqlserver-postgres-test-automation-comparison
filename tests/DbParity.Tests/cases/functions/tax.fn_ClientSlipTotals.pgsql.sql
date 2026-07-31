SELECT c.ClientId, y.TaxYear, t.EmploymentIncome, t.InvestmentIncome,
       t.SelfEmploymentIncome, t.PensionIncome, t.OtherIncome, t.Deductions,
       t.TaxWithheld, t.CPPContributions, t.EIPremiums, t.SlipCount
FROM client.Client c
     CROSS JOIN ref.TaxYear y
     CROSS JOIN LATERAL tax.fn_ClientSlipTotals(c.ClientId, y.TaxYear) t
ORDER BY c.ClientId, y.TaxYear;
