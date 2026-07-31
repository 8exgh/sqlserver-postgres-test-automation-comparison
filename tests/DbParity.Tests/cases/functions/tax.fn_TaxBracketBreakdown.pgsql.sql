SELECT j.JurisdictionCode, v.Income, b.Ordinal, b.LowerBound, b.UpperBound, b.Rate,
       b.IncomeInBracket, b.TaxInBracket, b.CumulativeTax
FROM ref.Jurisdiction j
     CROSS JOIN (VALUES (0.00), (55867.00), (111733.01), (250000.00)) AS v(Income)
     CROSS JOIN LATERAL tax.fn_TaxBracketBreakdown(j.JurisdictionCode, 2024, v.Income) b
ORDER BY j.JurisdictionCode, v.Income, b.Ordinal;
