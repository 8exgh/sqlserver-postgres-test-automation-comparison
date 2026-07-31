-- @name      util.fn_BusinessDaysBetween · weekends and statutory holidays
-- @category  function-scalar
--
-- Ranges deliberately span Christmas, Canada Day and a Monday-to-Monday week.
-- db/README.md notes the SQL Server original avoids DATEPART(WEEKDAY, ...)
-- because it depends on SET DATEFIRST -- this is what checks the port kept that.
SELECT j.JurisdictionCode, v.FromDate, v.ToDate,
       util.fn_BusinessDaysBetween(v.FromDate, v.ToDate, j.JurisdictionCode) AS BusinessDays
FROM ref.Jurisdiction j
CROSS JOIN (VALUES (CAST('2024-01-01' AS DATE), CAST('2024-01-31' AS DATE)),
                   (CAST('2024-06-24' AS DATE), CAST('2024-07-08' AS DATE)),
                   (CAST('2024-12-20' AS DATE), CAST('2025-01-06' AS DATE)),
                   (CAST('2024-03-04' AS DATE), CAST('2024-03-11' AS DATE)),
                   (CAST('2024-05-10' AS DATE), CAST('2024-05-10' AS DATE)),
                   (CAST('2024-05-10' AS DATE), CAST('2024-05-09' AS DATE))) AS v(FromDate, ToDate)
ORDER BY j.JurisdictionCode, v.FromDate, v.ToDate;
