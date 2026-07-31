-- @name      ref.fn_SalesTaxRate · every province, across rate changes
-- @category  function-tax
--
-- The dates straddle the seeded effective-from boundaries, so a date-range
-- comparison ported with the wrong inclusivity shows up here.
SELECT p.ProvinceCode, v.AsOf, ref.fn_SalesTaxRate(p.ProvinceCode, v.AsOf) AS Rate
FROM ref.Province p
CROSS JOIN (VALUES (CAST('2023-01-01' AS DATE)), (CAST('2023-06-30' AS DATE)),
                   (CAST('2024-01-01' AS DATE)), (CAST('2024-12-31' AS DATE)),
                   (CAST('2025-01-01' AS DATE)), (CAST('2025-12-31' AS DATE))) AS v(AsOf)
ORDER BY p.ProvinceCode, v.AsOf;
