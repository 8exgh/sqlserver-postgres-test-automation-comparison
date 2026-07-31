-- @name      payroll.vw_YearToDatePayroll · full contents
-- @category  view
--
-- Year-to-date window sums per employee. Partitioning and ordering inside the
-- window are what a port gets subtly wrong.
SELECT *
FROM payroll.vw_YearToDatePayroll
ORDER BY ClientId, TaxYear, EmployeeId, PayPeriodId;
