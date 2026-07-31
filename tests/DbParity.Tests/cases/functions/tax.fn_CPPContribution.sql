-- @name      tax.fn_CPPContribution · exemption and YMPE cap
-- @category  function-payroll
--
-- Earnings chosen to sit below the basic exemption, between exemption and YMPE,
-- and above the cap, where the result must flatten.
SELECT y.TaxYear, v.Earnings, tax.fn_CPPContribution(y.TaxYear, v.Earnings) AS Contribution
FROM ref.TaxYear y
CROSS JOIN (VALUES (0.00), (3500.00), (3500.01), (25000.00), (68500.00),
                   (68500.01), (73200.00), (100000.00)) AS v(Earnings)
ORDER BY y.TaxYear, v.Earnings;
