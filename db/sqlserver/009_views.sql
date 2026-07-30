/*==============================================================================
  009 - Views

  Nine views, including one indexed (materialized) view. The SET statements
  below are required for the indexed view: they must be in force both when its
  clustered index is created and whenever its base tables are written to. They
  are also set as database defaults in 001 so that ordinary client connections
  inherit them.
==============================================================================*/
USE CdnTaxPractice;
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

/*--------------------------------------------------------------------------
  1. Client directory - client joined to its primary address.

  This is the target of an INSTEAD OF INSERT trigger (011), which is what lets
  a caller create a client and its address in a single INSERT even though the
  view spans two tables and would otherwise not be insertable.
--------------------------------------------------------------------------*/
CREATE OR ALTER VIEW client.vw_ClientDirectory
AS
SELECT c.ClientId,
       c.ClientCode,
       c.ClientType,
       c.DisplayName,
       c.FirstName,
       c.LastName,
       c.LegalName,
       c.SIN,
       c.BusinessNumber,
       c.ProvinceCode,
       p.ProvinceName,
       c.IsActive,
       c.OnboardedDate,
       a.AddressId,
       a.Line1,
       a.Line2,
       a.City,
       a.PostalCode,
       e.ContactValue AS PrimaryEmail
FROM   client.Client        AS c
JOIN   ref.Province         AS p ON p.ProvinceCode = c.ProvinceCode
LEFT   JOIN client.ClientAddress AS a
       ON a.ClientId = c.ClientId AND a.IsPrimary = 1
LEFT   JOIN client.ClientContact AS e
       ON e.ClientId = c.ClientId AND e.IsPrimary = 1 AND e.ContactType = N'Email';
GO

/*--------------------------------------------------------------------------
  2. T1 summary - the assessed figures side by side with a live recalculation.

  A non-zero variance means the stored assessment no longer agrees with the
  rate tables, which is exactly the condition tax.usp_RecalculateAllReturns
  exists to clear.
--------------------------------------------------------------------------*/
CREATE OR ALTER VIEW tax.vw_T1ReturnSummary
AS
SELECT r.T1ReturnId,
       r.ClientId,
       c.ClientCode,
       c.DisplayName,
       r.TaxYear,
       r.ProvinceOfResidence,
       r.FilingStatus,
       r.TotalIncome,
       r.TotalDeductions,
       r.NetIncome,
       r.TaxableIncome,

       r.FederalTax                                                        AS AssessedFederalTax,
       tax.fn_FederalTax(r.TaxYear, r.TaxableIncome)                       AS RecalculatedFederalTax,
       r.FederalTax - tax.fn_FederalTax(r.TaxYear, r.TaxableIncome)        AS FederalTaxVariance,

       r.ProvincialTax                                                     AS AssessedProvincialTax,
       tax.fn_ProvincialTax(r.ProvinceOfResidence, r.TaxYear, r.TaxableIncome)
                                                                           AS RecalculatedProvincialTax,
       r.ProvincialTax - tax.fn_ProvincialTax(r.ProvinceOfResidence, r.TaxYear, r.TaxableIncome)
                                                                           AS ProvincialTaxVariance,

       r.NetFederalTax,
       r.NetProvincialTax,
       tax.fn_MarginalRate(r.ProvinceOfResidence, r.TaxYear, r.TaxableIncome) AS MarginalRate,
       -- Average rate on taxable income; NULLIF keeps a zero-income return
       -- from raising a divide-by-zero.
       CONVERT(DECIMAL(9, 6),
           (r.NetFederalTax + r.NetProvincialTax) / NULLIF(r.TaxableIncome, 0)) AS AverageRate,

       r.TaxWithheld,
       r.InstallmentsPaid,
       r.TotalPayable,
       r.BalanceOwing,
       r.DateFiled,
       r.CalculatedAt,
       r.AssessedAt
FROM   tax.T1Return   AS r
JOIN   client.Client  AS c ON c.ClientId = r.ClientId;
GO

/*--------------------------------------------------------------------------
  3. GST/HST returns that are unfiled or still carry a balance.
--------------------------------------------------------------------------*/
CREATE OR ALTER VIEW tax.vw_OutstandingGSTHST
AS
SELECT g.GSTHSTReturnId,
       g.ClientId,
       c.ClientCode,
       c.DisplayName,
       c.BusinessNumber,
       g.PeriodStart,
       g.PeriodEnd,
       f.Description                                              AS FilingFrequency,
       g.Line101Sales,
       g.Line105TaxCollected,
       g.Line108InputTaxCredits,
       g.Line109NetTax,
       g.PaymentsMade,
       g.BalanceDue,
       g.FilingDueDate,
       g.FiledAt,
       g.Status,
       DATEDIFF(DAY, g.FilingDueDate, CONVERT(DATE, SYSUTCDATETIME())) AS DaysPastDue,
       CASE WHEN g.FiledAt IS NULL THEN N'Not filed'
            WHEN g.BalanceDue > 0  THEN N'Filed, balance owing'
            ELSE N'Filed, refund due'
       END                                                        AS Situation
FROM   tax.GSTHSTReturn      AS g
JOIN   client.Client         AS c ON c.ClientId      = g.ClientId
JOIN   ref.FilingFrequency   AS f ON f.FrequencyCode = g.FrequencyCode
WHERE  g.FiledAt IS NULL
   OR  g.BalanceDue <> 0;
GO

/*--------------------------------------------------------------------------
  4. Receivables aged into buckets, one row per client.

  Built with PIVOT over acct.fn_InvoiceAging. Being "as at today" makes this a
  reporting view rather than a deterministic one - assertions against it must
  be structural, not value-based.
--------------------------------------------------------------------------*/
CREATE OR ALTER VIEW acct.vw_InvoiceAging
AS
SELECT pv.ClientId,
       c.ClientCode,
       c.DisplayName,
       ISNULL(pv.[Current], 0) AS CurrentAmount,
       ISNULL(pv.[1-30],   0)  AS Days1To30,
       ISNULL(pv.[31-60],  0)  AS Days31To60,
       ISNULL(pv.[61-90],  0)  AS Days61To90,
       ISNULL(pv.[90+],    0)  AS Days90Plus,
       ISNULL(pv.[Current], 0) + ISNULL(pv.[1-30], 0) + ISNULL(pv.[31-60], 0)
         + ISNULL(pv.[61-90], 0) + ISNULL(pv.[90+], 0) AS TotalOutstanding
FROM
(
    SELECT ag.ClientId, ag.AgingBucket, ag.OutstandingAmount
    FROM   acct.fn_InvoiceAging(CONVERT(DATE, SYSUTCDATETIME())) AS ag
) AS src
PIVOT
(
    SUM(src.OutstandingAmount)
    FOR src.AgingBucket IN ([Current], [1-30], [31-60], [61-90], [90+])
) AS pv
JOIN client.Client AS c ON c.ClientId = pv.ClientId;
GO

/*--------------------------------------------------------------------------
  5. General ledger with a per-account running balance.

  The window frame is explicit: without ROWS BETWEEN ... CURRENT ROW the
  default frame is RANGE, which would lump together every line sharing an
  entry date and give the wrong running total.
--------------------------------------------------------------------------*/
CREATE OR ALTER VIEW acct.vw_GeneralLedger
AS
SELECT e.ClientId,
       e.FiscalYearId,
       e.JournalEntryId,
       e.EntryNumber,
       e.EntryDate,
       e.Description,
       e.Source,
       l.JournalLineId,
       l.LineNumber,
       a.AccountId,
       a.AccountNumber,
       a.AccountName,
       t.NormalBalance,
       l.DebitAmount,
       l.CreditAmount,
       l.Memo,
       SUM(l.DebitAmount - l.CreditAmount) OVER
           (PARTITION BY a.AccountId
            ORDER BY e.EntryDate, e.JournalEntryId, l.LineNumber
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RunningDebitBalance,
       ROW_NUMBER() OVER
           (PARTITION BY a.AccountId
            ORDER BY e.EntryDate, e.JournalEntryId, l.LineNumber) AS AccountLineSequence
FROM   acct.JournalEntry AS e
JOIN   acct.JournalLine  AS l ON l.JournalEntryId  = e.JournalEntryId
JOIN   acct.Account      AS a ON a.AccountId       = l.AccountId
JOIN   ref.AccountType   AS t ON t.AccountTypeCode = a.AccountTypeCode
WHERE  e.IsPosted = 1;
GO

/*--------------------------------------------------------------------------
  6. INDEXED VIEW - revenue and expense totals per client per fiscal year.

  The rules this has to satisfy are why it looks so plain: SCHEMABINDING with
  two-part names, inner joins only, no subqueries or outer joins, no DISTINCT,
  and COUNT_BIG(*) present alongside the aggregates. The result is physically
  materialized by the unique clustered index that follows.
--------------------------------------------------------------------------*/
CREATE OR ALTER VIEW acct.vw_FiscalYearRevenue
WITH SCHEMABINDING
AS
SELECT e.ClientId,
       e.FiscalYearId,
       t.AccountTypeCode,
       SUM(l.CreditAmount) AS TotalCredits,
       SUM(l.DebitAmount)  AS TotalDebits,
       COUNT_BIG(*)        AS LineCount
FROM   acct.JournalEntry AS e
JOIN   acct.JournalLine  AS l ON l.JournalEntryId  = e.JournalEntryId
JOIN   acct.Account      AS a ON a.AccountId       = l.AccountId
JOIN   ref.AccountType   AS t ON t.AccountTypeCode = a.AccountTypeCode
WHERE  e.IsPosted    = 1
  AND  t.IsNominal   = 1
GROUP BY e.ClientId, e.FiscalYearId, t.AccountTypeCode;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UCX_vw_FiscalYearRevenue'
                 AND object_id = OBJECT_ID('acct.vw_FiscalYearRevenue'))
    CREATE UNIQUE CLUSTERED INDEX UCX_vw_FiscalYearRevenue
        ON acct.vw_FiscalYearRevenue (ClientId, FiscalYearId, AccountTypeCode);
GO

/*--------------------------------------------------------------------------
  7. Payroll with year-to-date running totals per employee.

  YTD figures matter because CPP and EI both stop once an employee reaches the
  annual maximum, so the running totals are what a correct payroll run reads.
--------------------------------------------------------------------------*/
CREATE OR ALTER VIEW payroll.vw_YearToDatePayroll
AS
SELECT pp.ClientId,
       pp.TaxYear,
       pp.PayPeriodId,
       pp.PeriodNumber,
       pp.PayDate,
       emp.EmployeeId,
       emp.EmployeeNumber,
       emp.LastName,
       emp.FirstName,
       emp.ProvinceOfEmployment,
       ps.GrossPay,
       ps.CPPDeducted,
       ps.CPP2Deducted,
       ps.EIDeducted,
       ps.FederalTaxDeducted,
       ps.ProvincialTaxDeducted,
       ps.NetPay,
       SUM(ps.GrossPay) OVER (PARTITION BY emp.EmployeeId, pp.TaxYear
                              ORDER BY pp.PeriodNumber
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS YtdGrossPay,
       SUM(ps.CPPDeducted + ps.CPP2Deducted) OVER (PARTITION BY emp.EmployeeId, pp.TaxYear
                              ORDER BY pp.PeriodNumber
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS YtdCPP,
       SUM(ps.EIDeducted) OVER (PARTITION BY emp.EmployeeId, pp.TaxYear
                              ORDER BY pp.PeriodNumber
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS YtdEI,
       SUM(ps.FederalTaxDeducted + ps.ProvincialTaxDeducted) OVER
                             (PARTITION BY emp.EmployeeId, pp.TaxYear
                              ORDER BY pp.PeriodNumber
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS YtdIncomeTax,
       SUM(ps.NetPay) OVER (PARTITION BY emp.EmployeeId, pp.TaxYear
                              ORDER BY pp.PeriodNumber
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS YtdNetPay
FROM   payroll.Paystub   AS ps
JOIN   payroll.PayPeriod AS pp  ON pp.PayPeriodId = ps.PayPeriodId
JOIN   payroll.Employee  AS emp ON emp.EmployeeId = ps.EmployeeId;
GO

/*--------------------------------------------------------------------------
  8. One row per client pulling together every domain: filings, slips,
  receivables and sales tax. This is the view a practice dashboard would bind
  to, and the widest cross-schema read in the schema.
--------------------------------------------------------------------------*/
CREATE OR ALTER VIEW tax.vw_ClientTaxProfile
AS
SELECT c.ClientId,
       c.ClientCode,
       c.DisplayName,
       c.ClientType,
       c.ProvinceCode,
       p.ProvinceName,
       c.IsActive,
       ref.fn_SalesTaxRate(c.ProvinceCode, CONVERT(DATE, SYSUTCDATETIME())) AS CurrentSalesTaxRate,

       t1.LatestTaxYear,
       t1.LatestTaxableIncome,
       t1.LatestBalanceOwing,
       t1.ReturnCount,

       sl.SlipCount,
       ar.OutstandingReceivable,
       gst.UnfiledGSTHSTReturns,
       gst.GSTHSTBalanceDue,
       eng.OpenEngagements
FROM   client.Client AS c
JOIN   ref.Province  AS p ON p.ProvinceCode = c.ProvinceCode
OUTER APPLY
(
    SELECT COUNT(*)          AS ReturnCount,
           MAX(r.TaxYear)    AS LatestTaxYear,
           -- The figures for the most recent year only.
           MAX(CASE WHEN r.TaxYear = mr.MaxYear THEN r.TaxableIncome END) AS LatestTaxableIncome,
           MAX(CASE WHEN r.TaxYear = mr.MaxYear THEN r.BalanceOwing  END) AS LatestBalanceOwing
    FROM   tax.T1Return AS r
    CROSS  JOIN (SELECT MAX(r2.TaxYear) AS MaxYear
                 FROM   tax.T1Return AS r2
                 WHERE  r2.ClientId = c.ClientId) AS mr
    WHERE  r.ClientId = c.ClientId
) AS t1
OUTER APPLY
(
    SELECT COUNT(*) AS SlipCount
    FROM   tax.Slip AS s
    WHERE  s.ClientId = c.ClientId
) AS sl
OUTER APPLY
(
    SELECT ISNULL(SUM(ag.OutstandingAmount), 0) AS OutstandingReceivable
    FROM   acct.fn_InvoiceAging(CONVERT(DATE, SYSUTCDATETIME())) AS ag
    WHERE  ag.ClientId = c.ClientId
) AS ar
OUTER APPLY
(
    SELECT SUM(CASE WHEN g.FiledAt IS NULL THEN 1 ELSE 0 END) AS UnfiledGSTHSTReturns,
           ISNULL(SUM(g.BalanceDue), 0)                       AS GSTHSTBalanceDue
    FROM   tax.GSTHSTReturn AS g
    WHERE  g.ClientId = c.ClientId
) AS gst
OUTER APPLY
(
    SELECT COUNT(*) AS OpenEngagements
    FROM   client.Engagement AS en
    WHERE  en.ClientId = c.ClientId
      AND  en.Status  IN (N'Open', N'InProgress', N'AwaitingClient')
) AS eng;
GO

/*--------------------------------------------------------------------------
  9. Audit log shredded to one row per changed column.

  The triggers write each row image with FOR JSON PATH, WITHOUT_ARRAY_WRAPPER,
  so the payload is a JSON object and OPENJSON's [key] is the column name. The
  correlated OPENJSON in the APPLY pairs each new value with its old one.
--------------------------------------------------------------------------*/
CREATE OR ALTER VIEW audit.vw_RecentChanges
AS
SELECT cl.ChangeLogId,
       cl.SchemaName,
       cl.TableName,
       cl.PrimaryKeyValue,
       cl.Operation,
       cl.ChangedBy,
       cl.ChangedAt,
       COALESCE(nv.[key], ov.[key]) AS ColumnName,
       ov.value                     AS OldValue,
       nv.value                     AS NewValue,
       -- T-SQL has no boolean expression type, so the NULL cases have to be
       -- spelled out rather than compared as booleans.
       CASE WHEN cl.Operation <> 'U'                        THEN 0
            WHEN ov.value IS NULL AND nv.value IS NULL      THEN 0
            WHEN ov.value IS NULL OR  nv.value IS NULL      THEN 1
            WHEN ov.value <> nv.value                       THEN 1
            ELSE 0
       END                          AS IsChanged
FROM   audit.ChangeLog AS cl
OUTER  APPLY OPENJSON(cl.NewValues) AS nv
OUTER  APPLY
(
    SELECT o.[key], o.value
    FROM   OPENJSON(cl.OldValues) AS o
    WHERE  o.[key] = nv.[key]
) AS ov;
GO

PRINT '009 views ready.';
GO
