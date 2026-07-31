-- @name      tax.fn_ProvincialTax · every province and year
-- @category  function-tax
SELECT p.ProvinceCode, y.TaxYear, v.Income,
       tax.fn_ProvincialTax(p.ProvinceCode, y.TaxYear, v.Income) AS Tax
FROM ref.Province p
CROSS JOIN ref.TaxYear y
CROSS JOIN (VALUES (0.00), (15000.00), (55867.00), (55867.01), (57375.00), (90997.00), (111733.00),
             (111733.01), (173205.00), (177882.00), (246752.00), (253414.00), (500000.00)) AS v(Income)
ORDER BY p.ProvinceCode, y.TaxYear, v.Income;
