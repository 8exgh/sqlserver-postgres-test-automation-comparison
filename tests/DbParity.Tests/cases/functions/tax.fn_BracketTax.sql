-- @name      tax.fn_BracketTax · every jurisdiction and year
-- @category  function-tax
--
-- Driven from ref.Jurisdiction and ref.TaxYear rather than a literal list, so
-- the matrix follows the seed instead of drifting from it. Bracket coverage is
-- deliberately uneven (db/README.md): jurisdictions without brackets for a year
-- must return the same thing on both engines, whatever that is.
SELECT j.JurisdictionCode, y.TaxYear, v.Income,
       tax.fn_BracketTax(j.JurisdictionCode, y.TaxYear, v.Income) AS Tax
FROM ref.Jurisdiction j
CROSS JOIN ref.TaxYear y
CROSS JOIN (VALUES (0.00), (15000.00), (55867.00), (55867.01), (57375.00), (90997.00), (111733.00),
             (111733.01), (173205.00), (177882.00), (246752.00), (253414.00), (500000.00)) AS v(Income)
ORDER BY j.JurisdictionCode, y.TaxYear, v.Income;
