-- @name      tax.fn_TaxBracketBreakdown · per-bracket running total
-- @category  function-tax
--
-- Divergent by necessity: CROSS APPLY has no PostgreSQL spelling, so this is
-- one of the few cases with per-engine SQL. The rows compared are identical.
-- The cumulative column is what catches a running-total port that resets.
SELECT j.JurisdictionCode, v.Income, b.Ordinal, b.LowerBound, b.UpperBound, b.Rate,
       b.IncomeInBracket, b.TaxInBracket, b.CumulativeTax
FROM ref.Jurisdiction j
     CROSS JOIN (VALUES (0.00), (55867.00), (111733.01), (250000.00)) AS v(Income)
     CROSS APPLY tax.fn_TaxBracketBreakdown(j.JurisdictionCode, 2024, v.Income) b
ORDER BY j.JurisdictionCode, v.Income, b.Ordinal;
