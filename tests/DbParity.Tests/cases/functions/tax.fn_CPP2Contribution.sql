-- @name      tax.fn_CPP2Contribution · second tier between YMPE and YAMPE
-- @category  function-payroll
SELECT y.TaxYear, v.Earnings, tax.fn_CPP2Contribution(y.TaxYear, v.Earnings) AS Contribution
FROM ref.TaxYear y
CROSS JOIN (VALUES (0.00), (68500.00), (68500.01), (70000.00), (73200.00),
                   (73200.01), (100000.00)) AS v(Earnings)
ORDER BY y.TaxYear, v.Earnings;
