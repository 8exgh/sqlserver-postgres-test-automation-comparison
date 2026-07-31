-- @name      tax.fn_EIPremium · MIE cap and the separate Quebec rate
-- @category  function-payroll
--
-- Quebec is included explicitly: it carries its own rate, so a port that lost
-- the special case would still look correct everywhere else.
SELECT p.ProvinceCode, y.TaxYear, v.Earnings,
       tax.fn_EIPremium(y.TaxYear, v.Earnings, p.ProvinceCode) AS Premium
FROM ref.Province p
CROSS JOIN ref.TaxYear y
CROSS JOIN (VALUES (0.00), (25000.00), (63200.00), (63200.01), (100000.00)) AS v(Earnings)
ORDER BY p.ProvinceCode, y.TaxYear, v.Earnings;
