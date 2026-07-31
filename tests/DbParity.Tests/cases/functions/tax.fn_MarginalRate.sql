-- @name      tax.fn_MarginalRate · combined federal and provincial
-- @category  function-tax
--
-- The most sensitive of the tax functions to a bracket-boundary off-by-one:
-- the rate steps exactly at a boundary, so income+0.01 must land in the next
-- bracket on both engines.
SELECT p.ProvinceCode, y.TaxYear, v.Income,
       tax.fn_MarginalRate(p.ProvinceCode, y.TaxYear, v.Income) AS MarginalRate
FROM ref.Province p
CROSS JOIN ref.TaxYear y
CROSS JOIN (VALUES (0.00), (15000.00), (55867.00), (55867.01), (57375.00), (90997.00), (111733.00),
             (111733.01), (173205.00), (177882.00), (246752.00), (253414.00), (500000.00)) AS v(Income)
ORDER BY p.ProvinceCode, y.TaxYear, v.Income;
