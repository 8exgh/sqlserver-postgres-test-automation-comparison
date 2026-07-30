/*==============================================================================
  099 - Verification

  The acceptance gate for the schema. Collects every failure into #Failures and
  raises once at the end, so a single run reports everything that is wrong
  rather than stopping at the first problem.

  Three layers:
    1. inventory  - the expected objects all exist and compiled
    2. behaviour  - functions return known-correct values
    3. contracts  - procedures and triggers raise the errors they promise

  #Failures is a temp table rather than a table variable specifically so it
  survives the GO batch separators below.

  Section 4 creates and deletes three scratch clients. It leaves the database
  otherwise byte-identical, with one deliberate exception: audit.ChangeLog is
  append-only and permanently records those eight scratch operations. That is
  the audit log working, not drift - every other table returns to exactly the
  row count it had before.
==============================================================================*/
USE CdnTaxPractice;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ARITHABORT ON;
GO

DROP TABLE IF EXISTS #Failures;
CREATE TABLE #Failures
(
    Seq       INT IDENTITY (1, 1) PRIMARY KEY,
    Category  NVARCHAR(20)  NOT NULL,
    Assertion NVARCHAR(160) NOT NULL,
    Expected  NVARCHAR(100) NOT NULL,
    Actual    NVARCHAR(100) NOT NULL
);
GO

/*------------------------------------------------------------------------------
  Clear any scratch clients left behind by a run that aborted before reaching
  its own cleanup. This happens first, before the seed-integrity counts below,
  so a previous failure cannot make this run report phantom problems. The
  delete cascades to their addresses, contacts and invoices.
------------------------------------------------------------------------------*/
DELETE FROM client.Client WHERE ClientCode LIKE N'VERIFY-%';
GO

/*==============================================================================
  1. INVENTORY
==============================================================================*/
PRINT '--- 1. inventory ---';

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'inventory', x.Assertion, CONVERT(NVARCHAR(100), x.Expected), CONVERT(NVARCHAR(100), x.Actual)
FROM (
    SELECT 'user tables'                 AS Assertion, 39 AS Expected,
           (SELECT COUNT(*) FROM sys.objects WHERE type = 'U'  AND is_ms_shipped = 0) AS Actual
    UNION ALL SELECT 'views',                          9,
           (SELECT COUNT(*) FROM sys.objects WHERE type = 'V'  AND is_ms_shipped = 0)
    UNION ALL SELECT 'scalar functions',              15,
           (SELECT COUNT(*) FROM sys.objects WHERE type = 'FN' AND is_ms_shipped = 0)
    UNION ALL SELECT 'inline table-valued functions',  3,
           (SELECT COUNT(*) FROM sys.objects WHERE type = 'IF' AND is_ms_shipped = 0)
    UNION ALL SELECT 'multi-statement table functions',2,
           (SELECT COUNT(*) FROM sys.objects WHERE type = 'TF' AND is_ms_shipped = 0)
    UNION ALL SELECT 'stored procedures',             12,
           (SELECT COUNT(*) FROM sys.objects WHERE type = 'P'  AND is_ms_shipped = 0)
    UNION ALL SELECT 'triggers',                       4,
           (SELECT COUNT(*) FROM sys.objects WHERE type = 'TR' AND is_ms_shipped = 0)
    UNION ALL SELECT 'sequences',                      1,
           (SELECT COUNT(*) FROM sys.sequences)
    UNION ALL SELECT 'synonyms',                       1,
           (SELECT COUNT(*) FROM sys.synonyms)
    UNION ALL SELECT 'user-defined table types',       3,
           (SELECT COUNT(*) FROM sys.table_types WHERE is_user_defined = 1)
    UNION ALL SELECT 'schemas',                        7,
           (SELECT COUNT(*) FROM sys.schemas
            WHERE name IN ('ref','client','tax','acct','payroll','audit','util'))
    UNION ALL SELECT 'indexed (materialized) views',   1,
           (SELECT COUNT(*) FROM sys.indexes i
            JOIN sys.views v ON v.object_id = i.object_id WHERE i.index_id = 1)
    UNION ALL SELECT 'filtered indexes',              10,
           (SELECT COUNT(*) FROM sys.indexes WHERE has_filter = 1)
    UNION ALL SELECT 'computed columns',              18,
           (SELECT COUNT(*) FROM sys.computed_columns)
) AS x
WHERE x.Expected <> x.Actual;

-- Every module must have compiled, and the ones that must be schema-bound are.
INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'inventory', 'acct.vw_FiscalYearRevenue is schema-bound', '1',
       CONVERT(NVARCHAR(100), ISNULL(MAX(CONVERT(INT, m.is_schema_bound)), -1))
FROM   sys.sql_modules AS m
WHERE  m.object_id = OBJECT_ID('acct.vw_FiscalYearRevenue')
HAVING ISNULL(MAX(CONVERT(INT, m.is_schema_bound)), -1) <> 1;

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'inventory', 'all 20 functions are schema-bound', '20',
       CONVERT(NVARCHAR(100), COUNT(*))
FROM   sys.sql_modules AS m
JOIN   sys.objects     AS o ON o.object_id = m.object_id
WHERE  o.type IN ('FN', 'IF', 'TF')
  AND  m.is_schema_bound = 1
HAVING COUNT(*) <> 20;

-- Anything that failed to bind shows up here with a NULL referenced id. The
-- trigger pseudo-tables "inserted" and "deleted" also have no object id and
-- are excluded - they are unresolved by definition, not by mistake.
INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'inventory', 'no module has unresolved references', '0',
       CONVERT(NVARCHAR(100), COUNT(*))
FROM   sys.sql_expression_dependencies AS d
WHERE  d.referenced_id IS NULL
  AND  d.referenced_server_name IS NULL
  AND  d.referenced_database_name IS NULL
  AND  d.is_ambiguous = 0
  AND  NOT (d.referenced_entity_name IN (N'inserted', N'deleted')
            AND OBJECTPROPERTY(d.referencing_id, 'IsTrigger') = 1)
HAVING COUNT(*) <> 0;
GO

/*==============================================================================
  2. BEHAVIOUR - pure functions against known-correct values
==============================================================================*/
PRINT '--- 2. function behaviour ---';

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'function', x.Assertion, x.Expected, x.Actual
FROM (VALUES
    /*--- identifier validation ---------------------------------------*/
    ('fn_IsValidSIN accepts a valid check digit',
     '1', CONVERT(NVARCHAR(100), tax.fn_IsValidSIN('046454286'))),
    ('fn_IsValidSIN rejects a mutated last digit',
     '0', CONVERT(NVARCHAR(100), tax.fn_IsValidSIN('046454287'))),
    ('fn_IsValidSIN rejects a non-numeric value',
     '0', CONVERT(NVARCHAR(100), tax.fn_IsValidSIN('04645428X'))),
    ('fn_IsValidBusinessNumber accepts a full RT account',
     '1', CONVERT(NVARCHAR(100), tax.fn_IsValidBusinessNumber('867530909RT0001'))),
    ('fn_IsValidBusinessNumber accepts the bare 9 digits',
     '1', CONVERT(NVARCHAR(100), tax.fn_IsValidBusinessNumber('867530909'))),
    ('fn_IsValidBusinessNumber rejects an unknown program id',
     '0', CONVERT(NVARCHAR(100), tax.fn_IsValidBusinessNumber('867530909RX0001'))),
    ('fn_IsValidBusinessNumber rejects a bad check digit',
     '0', CONVERT(NVARCHAR(100), tax.fn_IsValidBusinessNumber('867530900'))),

    /*--- income tax ---------------------------------------------------*/
    -- 55,867 @ 15% + 44,133 @ 20.5%
    ('fn_FederalTax(2024, 100000)',
     '17427.32', CONVERT(NVARCHAR(100), tax.fn_FederalTax(2024, 100000.00))),
    -- 51,446 @ 5.05% + 48,554 @ 9.15%
    ('fn_ProvincialTax(ON, 2024, 100000)',
     '7040.71',  CONVERT(NVARCHAR(100), tax.fn_ProvincialTax('ON', 2024, 100000.00))),
    ('fn_FederalTax on zero income is zero',
     '0.00',     CONVERT(NVARCHAR(100), tax.fn_FederalTax(2024, 0.00))),
    ('fn_FederalTax on negative income is zero',
     '0.00',     CONVERT(NVARCHAR(100), tax.fn_FederalTax(2024, -5000.00))),
    -- Income entirely inside the first bracket.
    ('fn_FederalTax(2024, 40000) = 40000 * 15%',
     '6000.00',  CONVERT(NVARCHAR(100), tax.fn_FederalTax(2024, 40000.00))),
    ('fn_MarginalRate(ON, 2024, 100000) = 20.5% + 9.15%',
     '0.296500', CONVERT(NVARCHAR(100), tax.fn_MarginalRate('ON', 2024, 100000.00))),
    -- Alberta's 2025 first bracket is 8%, a rate that did not exist in 2024.
    ('fn_ProvincialTax(AB, 2025, 50000) uses the new 8% bracket',
     '4000.00',  CONVERT(NVARCHAR(100), tax.fn_ProvincialTax('AB', 2025, 50000.00))),

    /*--- payroll ------------------------------------------------------*/
    -- (68,500 - 3,500) * 5.95% = the 2024 annual maximum
    ('fn_CPPContribution(2024, 100000) is the annual maximum',
     '3867.50',  CONVERT(NVARCHAR(100), tax.fn_CPPContribution(2024, 100000.00))),
    -- (73,200 - 68,500) * 4%
    ('fn_CPP2Contribution(2024, 100000) is the CPP2 maximum',
     '188.00',   CONVERT(NVARCHAR(100), tax.fn_CPP2Contribution(2024, 100000.00))),
    ('fn_CPP2Contribution below the YMPE is zero',
     '0.00',     CONVERT(NVARCHAR(100), tax.fn_CPP2Contribution(2024, 60000.00))),
    ('fn_CPP2Contribution did not exist in 2023',
     '0.00',     CONVERT(NVARCHAR(100), tax.fn_CPP2Contribution(2023, 100000.00))),
    -- 63,200 * 1.66%
    ('fn_EIPremium(2024, 100000, ON) is the annual maximum',
     '1049.12',  CONVERT(NVARCHAR(100), tax.fn_EIPremium(2024, 100000.00, 'ON'))),
    -- 63,200 * 1.32% - Quebec uses its own rate
    ('fn_EIPremium(2024, 100000, QC) uses the Quebec rate',
     '834.24',   CONVERT(NVARCHAR(100), tax.fn_EIPremium(2024, 100000.00, 'QC'))),
    ('fn_CPPContribution below the basic exemption is zero',
     '0.00',     CONVERT(NVARCHAR(100), tax.fn_CPPContribution(2024, 3000.00))),

    /*--- sales tax ----------------------------------------------------*/
    ('fn_GSTHSTRate(ON) is 13% HST',
     '0.13000',  CONVERT(NVARCHAR(100), ref.fn_GSTHSTRate('ON', '2024-06-01'))),
    ('fn_GSTHSTRate(AB) is 5% GST',
     '0.05000',  CONVERT(NVARCHAR(100), ref.fn_GSTHSTRate('AB', '2024-06-01'))),
    ('fn_GSTHSTRate(NS) before 2025-04-01 is 15%',
     '0.15000',  CONVERT(NVARCHAR(100), ref.fn_GSTHSTRate('NS', '2025-01-15'))),
    ('fn_GSTHSTRate(NS) on and after 2025-04-01 is 14%',
     '0.14000',  CONVERT(NVARCHAR(100), ref.fn_GSTHSTRate('NS', '2025-06-15'))),
    ('fn_SalesTaxRate(QC) is GST 5% + QST 9.975%',
     '0.14975',  CONVERT(NVARCHAR(100), ref.fn_SalesTaxRate('QC', '2024-06-01'))),
    ('fn_PSTRate(BC) is 7%',
     '0.07000',  CONVERT(NVARCHAR(100), ref.fn_PSTRate('BC', '2024-06-01'))),

    /*--- dates --------------------------------------------------------*/
    -- Dec 23, 24, 27, 30, 31 - Christmas, Boxing Day, New Year and both
    -- weekends excluded.
    ('fn_BusinessDaysBetween over the 2024 holidays',
     '5', CONVERT(NVARCHAR(100), util.fn_BusinessDaysBetween('2024-12-23', '2025-01-02', 'ON'))),
    -- Feb 17 2025 is Family Day in Ontario but an ordinary Monday in Quebec.
    ('fn_BusinessDaysBetween respects a province-only holiday (ON)',
     '4', CONVERT(NVARCHAR(100), util.fn_BusinessDaysBetween('2025-02-17', '2025-02-22', 'ON'))),
    ('fn_BusinessDaysBetween respects a province-only holiday (QC)',
     '5', CONVERT(NVARCHAR(100), util.fn_BusinessDaysBetween('2025-02-17', '2025-02-22', 'QC'))),
    ('fn_BusinessDaysBetween on an inverted range is zero',
     '0', CONVERT(NVARCHAR(100), util.fn_BusinessDaysBetween('2025-03-01', '2025-02-01', 'ON')))
) AS x (Assertion, Expected, Actual)
WHERE x.Expected <> x.Actual;

/*--- the bracket breakdown must reconcile to the scalar function ----------
  A one-cent tolerance is correct rather than lax: the breakdown rounds each
  bracket individually while fn_BracketTax rounds the total once, so the two
  can legitimately differ by a cent.
--------------------------------------------------------------------------*/
INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'function',
       CONCAT('fn_TaxBracketBreakdown reconciles to fn_FederalTax at ', i.Income),
       CONVERT(NVARCHAR(100), tax.fn_FederalTax(2024, i.Income)),
       CONVERT(NVARCHAR(100), b.BreakdownTotal)
FROM   (VALUES (25000.00), (100000.00), (180000.00), (400000.00)) AS i (Income)
CROSS  APPLY (SELECT ISNULL(SUM(bb.TaxInBracket), 0) AS BreakdownTotal
              FROM   tax.fn_TaxBracketBreakdown('CA', 2024, i.Income) AS bb) AS b
WHERE  ABS(b.BreakdownTotal - tax.fn_FederalTax(2024, i.Income)) > 0.01;

-- CumulativeTax on the last bracket row must equal the sum of all rows.
INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'function', 'fn_TaxBracketBreakdown cumulative column is a running total',
       CONVERT(NVARCHAR(100), t.Total), CONVERT(NVARCHAR(100), t.LastCumulative)
FROM   (SELECT SUM(bb.TaxInBracket) AS Total,
               MAX(bb.CumulativeTax) AS LastCumulative
        FROM   tax.fn_TaxBracketBreakdown('CA', 2024, 300000.00) AS bb) AS t
WHERE  t.Total <> t.LastCumulative;
GO

/*==============================================================================
  3. SEED DATA INTEGRITY
==============================================================================*/
PRINT '--- 3. seed data integrity ---';

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'seed', x.Assertion, CONVERT(NVARCHAR(100), x.Expected), CONVERT(NVARCHAR(100), x.Actual)
FROM (
    SELECT 'clients seeded' AS Assertion, 25 AS Expected,
           (SELECT COUNT(*) FROM client.Client) AS Actual
    UNION ALL SELECT 'every seeded SIN passes its check digit', 0,
           (SELECT COUNT(*) FROM client.Client
            WHERE SIN IS NOT NULL AND tax.fn_IsValidSIN(SIN) = 0)
    UNION ALL SELECT 'every seeded business number passes its check digit', 0,
           (SELECT COUNT(*) FROM client.Client
            WHERE BusinessNumber IS NOT NULL AND tax.fn_IsValidBusinessNumber(BusinessNumber) = 0)
    UNION ALL SELECT 'every employee SIN passes its check digit', 0,
           (SELECT COUNT(*) FROM payroll.Employee WHERE tax.fn_IsValidSIN(SIN) = 0)
    UNION ALL SELECT 'every journal entry balances', 0,
           (SELECT COUNT(*) FROM (SELECT JournalEntryId FROM acct.JournalLine
                                  GROUP BY JournalEntryId
                                  HAVING SUM(DebitAmount) <> SUM(CreditAmount)) AS x)
    UNION ALL SELECT 'every invoice header agrees with its lines', 0,
           (SELECT COUNT(*) FROM acct.Invoice AS i
            CROSS APPLY (SELECT ISNULL(SUM(l.LineTotal), 0) AS LineSum
                         FROM acct.InvoiceLine AS l WHERE l.InvoiceId = i.InvoiceId) AS s
            WHERE i.Subtotal <> s.LineSum)
    UNION ALL SELECT 'no assessed T1 lacks a notice of assessment number', 0,
           (SELECT COUNT(*) FROM tax.T1Return
            WHERE FilingStatus = N'Assessed' AND NoticeOfAssessmentNo IS NULL)
    UNION ALL SELECT 'federal brackets cover 2023-2025', 3,
           (SELECT COUNT(DISTINCT TaxYear) FROM ref.TaxBracket WHERE JurisdictionCode = 'CA')
    UNION ALL SELECT 'ON/BC/AB/QC brackets cover 3 years each', 4,
           (SELECT COUNT(*) FROM (SELECT JurisdictionCode FROM ref.TaxBracket
                                  WHERE JurisdictionCode IN ('ON','BC','AB','QC')
                                  GROUP BY JurisdictionCode
                                  HAVING COUNT(DISTINCT TaxYear) = 3) AS x)
    UNION ALL SELECT 'all 13 provinces have 2024 brackets', 13,
           (SELECT COUNT(DISTINCT JurisdictionCode) FROM ref.TaxBracket
            WHERE TaxYear = 2024 AND JurisdictionCode <> 'CA')
    UNION ALL SELECT 'no bracket set has a gap or overlap', 0,
           (SELECT COUNT(*) FROM ref.TaxBracket AS b
            JOIN ref.TaxBracket AS prev
                 ON  prev.TaxYear          = b.TaxYear
                 AND prev.JurisdictionCode = b.JurisdictionCode
                 AND prev.Ordinal          = b.Ordinal - 1
            WHERE prev.UpperBound <> b.LowerBound)
    UNION ALL SELECT 'exactly one fiscal year is closed', 1,
           (SELECT COUNT(*) FROM acct.FiscalYear WHERE IsClosed = 1)
    UNION ALL SELECT 'the 2023 tax year is locked', 1,
           (SELECT CONVERT(INT, IsLocked) FROM ref.TaxYear WHERE TaxYear = 2023)
    -- Counted as "every client has one", not as a fixed total: audit.ChangeLog
    -- is append-only and keeps rows for clients that were later deleted, so a
    -- fixed total would drift every time this script runs its scratch cases.
    UNION ALL SELECT 'every client has an insert audit row', 0,
           (SELECT COUNT(*) FROM client.Client AS c
            WHERE NOT EXISTS (SELECT 1 FROM audit.ChangeLog AS cl
                              WHERE cl.TableName       = N'Client'
                                AND cl.Operation       = 'I'
                                AND cl.PrimaryKeyValue = CONVERT(NVARCHAR(100), c.ClientId)))
    UNION ALL SELECT 'filing status transitions were recorded', 42,
           (SELECT COUNT(*) FROM audit.ReturnStatusHistory)
) AS x
WHERE x.Expected <> x.Actual;

/*--- every trial balance must balance ------------------------------------*/
INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'seed',
       CONCAT('trial balance balances for fiscal year ', fy.FiscalYearId),
       '0.00', CONVERT(NVARCHAR(100), tb.Balance)
FROM   acct.FiscalYear AS fy
CROSS  APPLY acct.fn_TrialBalance(fy.ClientId, fy.FiscalYearId, fy.EndDate) AS tb
WHERE  tb.IsTotalRow = 1
  AND  tb.Balance <> 0;

/*--- the recalculation must agree with what is stored --------------------*/
INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'seed', 'no stored T1 tax differs from a live recalculation', '0',
       CONVERT(NVARCHAR(100), COUNT(*))
FROM   tax.vw_T1ReturnSummary
WHERE  FederalTaxVariance <> 0 OR ProvincialTaxVariance <> 0
HAVING COUNT(*) <> 0;

/*--- the indexed view must agree with the aggregate it materializes ------*/
INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'seed', 'indexed view matches a direct aggregate', '0',
       CONVERT(NVARCHAR(100), COUNT(*))
FROM   acct.vw_FiscalYearRevenue AS v
JOIN   (SELECT e.ClientId, e.FiscalYearId, t.AccountTypeCode,
               SUM(l.CreditAmount) AS TotalCredits, COUNT_BIG(*) AS LineCount
        FROM   acct.JournalEntry AS e
        JOIN   acct.JournalLine  AS l ON l.JournalEntryId  = e.JournalEntryId
        JOIN   acct.Account      AS a ON a.AccountId       = l.AccountId
        JOIN   ref.AccountType   AS t ON t.AccountTypeCode = a.AccountTypeCode
        WHERE  e.IsPosted = 1 AND t.IsNominal = 1
        GROUP BY e.ClientId, e.FiscalYearId, t.AccountTypeCode) AS direct
       ON  direct.ClientId        = v.ClientId
       AND direct.FiscalYearId    = v.FiscalYearId
       AND direct.AccountTypeCode = v.AccountTypeCode
WHERE  direct.TotalCredits <> v.TotalCredits OR direct.LineCount <> v.LineCount
HAVING COUNT(*) <> 0;

/*--- payroll: CPP and EI must stop at the annual maximum ------------------*/
INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'seed', 'no employee exceeds the 2024 CPP maximum', '0',
       CONVERT(NVARCHAR(100), COUNT(*))
FROM   (SELECT ps.EmployeeId, SUM(ps.CPPDeducted) AS Cpp, SUM(ps.CPP2Deducted) AS Cpp2
        FROM   payroll.Paystub   AS ps
        JOIN   payroll.PayPeriod AS pp ON pp.PayPeriodId = ps.PayPeriodId
        WHERE  pp.TaxYear = 2024
        GROUP BY ps.EmployeeId) AS x
WHERE  x.Cpp > 3867.50 OR x.Cpp2 > 188.00
HAVING COUNT(*) <> 0;

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'seed', 'no employee exceeds the 2024 EI maximum', '0',
       CONVERT(NVARCHAR(100), COUNT(*))
FROM   (SELECT ps.EmployeeId, SUM(ps.EIDeducted) AS Ei
        FROM   payroll.Paystub   AS ps
        JOIN   payroll.PayPeriod AS pp ON pp.PayPeriodId = ps.PayPeriodId
        WHERE  pp.TaxYear = 2024
        GROUP BY ps.EmployeeId) AS x
WHERE  x.Ei > 1049.12
HAVING COUNT(*) <> 0;

/*--- the JSON audit payloads must actually shred --------------------------
  Asserted as "every logged insert yields exactly one ClientCode column" so
  the result does not depend on how many rows the log has accumulated.
--------------------------------------------------------------------------*/
INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'seed', 'audit.vw_RecentChanges shreds exactly one ClientCode per logged insert',
       '0', CONVERT(NVARCHAR(100), COUNT(*))
FROM   audit.ChangeLog AS cl
CROSS  APPLY (SELECT COUNT(*) AS Shredded
              FROM   audit.vw_RecentChanges AS v
              WHERE  v.ChangeLogId = cl.ChangeLogId
                AND  v.ColumnName  = N'ClientCode') AS s
WHERE  cl.TableName = N'Client'
  AND  cl.Operation = 'I'
  AND  s.Shredded <> 1
HAVING COUNT(*) <> 0;

-- And the shredded value must actually match the row it came from.
INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'seed', 'shredded ClientCode matches the client it was logged for',
       '0', CONVERT(NVARCHAR(100), COUNT(*))
FROM   audit.vw_RecentChanges AS v
JOIN   client.Client          AS c
       ON c.ClientId = TRY_CONVERT(INT, v.PrimaryKeyValue)
WHERE  v.TableName  = N'Client'
  AND  v.Operation  = 'I'
  AND  v.ColumnName = N'ClientCode'
  AND  v.NewValue  <> c.ClientCode
HAVING COUNT(*) <> 0;

/*--- the recursive hierarchy must reach the leaf accounts -----------------*/
INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'seed', 'fn_AccountHierarchy returns 21 accounts at depths 0 and 1',
       '21|0|1',
       CONCAT(COUNT(*), '|', MIN(h.Depth), '|', MAX(h.Depth))
FROM   client.Client AS c
CROSS  APPLY acct.fn_AccountHierarchy(c.ClientId, NULL) AS h
WHERE  c.ClientCode = N'COR-0001'
HAVING CONCAT(COUNT(*), '|', MIN(h.Depth), '|', MAX(h.Depth)) <> '21|0|1';
GO

/*==============================================================================
  4. CONTRACTS - the errors procedures and triggers promise to raise

  Each case runs inside TRY/CATCH and records the error number that came back,
  so a wrong error number is reported rather than aborting the script.
==============================================================================*/
PRINT '--- 4. procedure and trigger contracts ---';

DECLARE @caught INT, @scratchOn INT, @scratchAb INT, @dummy INT;

-- Several procedures return a result set as well as an OUTPUT parameter.
-- Capturing them with INSERT ... EXEC keeps this script's own output to just
-- the pass/fail report instead of a wall of incidental rows.
DECLARE @upsertOut TABLE (ClientId INT, MergeAction NVARCHAR(10));
DECLARE @invoiceOut TABLE
(
    InvoiceId     INT, InvoiceNumber INT, ProvinceCode CHAR(2),
    GSTHSTRate    DECIMAL(9, 5), PSTRate DECIMAL(9, 5),
    Subtotal      DECIMAL(19, 2), GSTHSTAmount DECIMAL(19, 2),
    PSTAmount     DECIMAL(19, 2), Total DECIMAL(19, 2)
);
DECLARE @purgeOut TABLE (RowsDeleted INT, BatchesRun INT, CutoffUtc DATETIME2(3));

/*--- 50040: invalid SIN rejected by usp_UpsertClient ---------------------*/
SET @caught = 0;
BEGIN TRY
    EXEC client.usp_UpsertClient
         @ClientCode = N'VERIFY-BAD-SIN', @ClientType = 'I', @ProvinceCode = 'ON',
         @FirstName = N'Bad', @LastName = N'Sin', @DateOfBirth = '1990-01-01',
         @SIN = '046454287', @ClientId = @dummy OUTPUT;
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
    -- An error raised inside a trigger dooms the ambient transaction. Clearing
    -- it here is what lets the next assertion run instead of the whole script
    -- dying with error 3930 on its next write.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_UpsertClient rejects an invalid SIN', '50040', CONVERT(NVARCHAR(100), @caught)
WHERE  @caught <> 50040;

/*--- 50042: a corporation without a legal name ---------------------------*/
SET @caught = 0;
BEGIN TRY
    EXEC client.usp_UpsertClient
         @ClientCode = N'VERIFY-BAD-CORP', @ClientType = 'C', @ProvinceCode = 'ON',
         @ClientId = @dummy OUTPUT;
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
    -- An error raised inside a trigger dooms the ambient transaction. Clearing
    -- it here is what lets the next assertion run instead of the whole script
    -- dying with error 3930 on its next write.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_UpsertClient rejects a corporation with no legal name',
       '50042', CONVERT(NVARCHAR(100), @caught)
WHERE  @caught <> 50042;

/*--- usp_UpsertClient inserts, then updates on a second call -------------*/
INSERT INTO @upsertOut
EXEC client.usp_UpsertClient
     @ClientCode = N'VERIFY-ON', @ClientType = 'I', @ProvinceCode = 'ON',
     @FirstName = N'Verify', @LastName = N'Ontario', @DateOfBirth = '1990-01-01',
     @SIN = '046454286', @OnboardedDate = '2024-01-01', @ClientId = @scratchOn OUTPUT;

INSERT INTO @upsertOut
EXEC client.usp_UpsertClient
     @ClientCode = N'VERIFY-AB', @ClientType = 'I', @ProvinceCode = 'AB',
     @FirstName = N'Verify', @LastName = N'Alberta', @DateOfBirth = '1990-01-01',
     @OnboardedDate = '2024-01-01', @ClientId = @scratchAb OUTPUT;

DELETE FROM @upsertOut;

DECLARE @secondCallId INT;
INSERT INTO @upsertOut
EXEC client.usp_UpsertClient
     @ClientCode = N'VERIFY-ON', @ClientType = 'I', @ProvinceCode = 'BC',
     @FirstName = N'Verify', @LastName = N'Ontario', @DateOfBirth = '1990-01-01',
     @SIN = '046454286', @ClientId = @secondCallId OUTPUT;

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_UpsertClient reports UPDATE on the second call',
       'UPDATE', CONVERT(NVARCHAR(100), MergeAction)
FROM   @upsertOut WHERE MergeAction <> N'UPDATE';

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_UpsertClient updates rather than duplicating on a second call',
       CONVERT(NVARCHAR(100), @scratchOn), CONVERT(NVARCHAR(100), @secondCallId)
WHERE  @scratchOn <> @secondCallId;

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'the second upsert applied its change', 'BC',
       CONVERT(NVARCHAR(100), ProvinceCode)
FROM   client.Client WHERE ClientId = @scratchOn AND ProvinceCode <> 'BC';

-- Put it back so the invoice test below bills an Ontario client.
UPDATE client.Client SET ProvinceCode = 'ON' WHERE ClientId = @scratchOn;

/*--- usp_GenerateInvoice applies the right rate per province -------------*/
DECLARE @invLines acct.InvoiceLineType, @invOn INT, @invAb INT;
INSERT INTO @invLines (LineNumber, Description, Quantity, UnitPrice, IsTaxable)
VALUES (1, N'Verification services', 1.00, 1000.00, 1);

INSERT INTO @invoiceOut
EXEC acct.usp_GenerateInvoice
     @ClientId = @scratchOn, @InvoiceDate = '2024-06-01',
     @Lines = @invLines, @Status = N'Draft', @InvoiceId = @invOn OUTPUT;

INSERT INTO @invoiceOut
EXEC acct.usp_GenerateInvoice
     @ClientId = @scratchAb, @InvoiceDate = '2024-06-01',
     @Lines = @invLines, @Status = N'Draft', @InvoiceId = @invAb OUTPUT;

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_GenerateInvoice charges 13% HST in Ontario',
       '130.00', CONVERT(NVARCHAR(100), GSTHSTAmount)
FROM   acct.Invoice WHERE InvoiceId = @invOn AND GSTHSTAmount <> 130.00;

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_GenerateInvoice charges 5% GST in Alberta',
       '50.00', CONVERT(NVARCHAR(100), GSTHSTAmount)
FROM   acct.Invoice WHERE InvoiceId = @invAb AND GSTHSTAmount <> 50.00;

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_GenerateInvoice allocates distinct invoice numbers',
       'distinct', 'duplicate'
WHERE  (SELECT InvoiceNumber FROM acct.Invoice WHERE InvoiceId = @invOn)
     = (SELECT InvoiceNumber FROM acct.Invoice WHERE InvoiceId = @invAb);

/*--- INSTEAD OF INSERT on the view fans out to three tables --------------*/
INSERT INTO client.vw_ClientDirectory
    (ClientCode, ClientType, FirstName, LastName, ProvinceCode,
     Line1, City, PostalCode, PrimaryEmail, IsActive, OnboardedDate)
VALUES
    (N'VERIFY-VIEW', 'I', N'Through', N'View', 'ON',
     N'1 Test Street', N'Toronto', 'M5V 1A1', N'through.view@example.ca', 1, '2024-01-01');

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'INSTEAD OF INSERT on the view created client + address + contact',
       '1|1|1',
       CONCAT((SELECT COUNT(*) FROM client.Client  WHERE ClientCode = N'VERIFY-VIEW'), '|',
              (SELECT COUNT(*) FROM client.ClientAddress a
               JOIN client.Client c ON c.ClientId = a.ClientId WHERE c.ClientCode = N'VERIFY-VIEW'), '|',
              (SELECT COUNT(*) FROM client.ClientContact ct
               JOIN client.Client c ON c.ClientId = ct.ClientId WHERE c.ClientCode = N'VERIFY-VIEW'))
WHERE  CONCAT((SELECT COUNT(*) FROM client.Client  WHERE ClientCode = N'VERIFY-VIEW'), '|',
              (SELECT COUNT(*) FROM client.ClientAddress a
               JOIN client.Client c ON c.ClientId = a.ClientId WHERE c.ClientCode = N'VERIFY-VIEW'), '|',
              (SELECT COUNT(*) FROM client.ClientContact ct
               JOIN client.Client c ON c.ClientId = ct.ClientId WHERE c.ClientCode = N'VERIFY-VIEW'))
       <> '1|1|1';

/*--- 50001: an unbalanced journal entry ----------------------------------*/
DECLARE @cor1 INT = (SELECT ClientId FROM client.Client WHERE ClientCode = N'COR-0001');
DECLARE @cor1Fy2025 INT = (SELECT FiscalYearId FROM acct.FiscalYear
                           WHERE ClientId = @cor1 AND YEAR(EndDate) = 2025);
DECLARE @jeLines acct.JournalLineType, @jeId INT;

INSERT INTO @jeLines (LineNumber, AccountNumber, DebitAmount, CreditAmount)
VALUES (1, N'1100', 100.00, 0.00),
       (2, N'4100', 0.00,  90.00);          -- deliberately 10.00 short

SET @caught = 0;
BEGIN TRY
    EXEC acct.usp_PostJournalEntry
         @ClientId = @cor1, @FiscalYearId = @cor1Fy2025, @EntryDate = '2025-03-01',
         @Description = N'Verification - should not post', @Lines = @jeLines,
         @JournalEntryId = @jeId OUTPUT;
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
    -- An error raised inside a trigger dooms the ambient transaction. Clearing
    -- it here is what lets the next assertion run instead of the whole script
    -- dying with error 3930 on its next write.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_PostJournalEntry rejects an unbalanced entry',
       '50001', CONVERT(NVARCHAR(100), @caught)
WHERE  @caught <> 50001;

/*--- 50002: an account number that does not exist ------------------------*/
DELETE FROM @jeLines;
INSERT INTO @jeLines (LineNumber, AccountNumber, DebitAmount, CreditAmount)
VALUES (1, N'9999', 100.00, 0.00),
       (2, N'4100', 0.00,  100.00);

SET @caught = 0;
BEGIN TRY
    EXEC acct.usp_PostJournalEntry
         @ClientId = @cor1, @FiscalYearId = @cor1Fy2025, @EntryDate = '2025-03-01',
         @Description = N'Verification - bad account', @Lines = @jeLines,
         @JournalEntryId = @jeId OUTPUT;
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
    -- An error raised inside a trigger dooms the ambient transaction. Clearing
    -- it here is what lets the next assertion run instead of the whole script
    -- dying with error 3930 on its next write.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_PostJournalEntry rejects an unknown account number',
       '50002', CONVERT(NVARCHAR(100), @caught)
WHERE  @caught <> 50002;

/*--- 50003: posting directly to a control account ------------------------*/
DELETE FROM @jeLines;
INSERT INTO @jeLines (LineNumber, AccountNumber, DebitAmount, CreditAmount)
VALUES (1, N'1000', 100.00, 0.00),          -- 1000 is a control account
       (2, N'4100', 0.00,  100.00);

SET @caught = 0;
BEGIN TRY
    EXEC acct.usp_PostJournalEntry
         @ClientId = @cor1, @FiscalYearId = @cor1Fy2025, @EntryDate = '2025-03-01',
         @Description = N'Verification - control account', @Lines = @jeLines,
         @JournalEntryId = @jeId OUTPUT;
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
    -- An error raised inside a trigger dooms the ambient transaction. Clearing
    -- it here is what lets the next assertion run instead of the whole script
    -- dying with error 3930 on its next write.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_PostJournalEntry refuses to post to a control account',
       '50003', CONVERT(NVARCHAR(100), @caught)
WHERE  @caught <> 50003;

/*--- 50004: posting into a closed fiscal year ----------------------------*/
DECLARE @cor7 INT = (SELECT ClientId FROM client.Client WHERE ClientCode = N'COR-0007');
DECLARE @cor7Closed INT = (SELECT FiscalYearId FROM acct.FiscalYear
                           WHERE ClientId = @cor7 AND IsClosed = 1);

DELETE FROM @jeLines;
INSERT INTO @jeLines (LineNumber, AccountNumber, DebitAmount, CreditAmount)
VALUES (1, N'1100', 100.00, 0.00),
       (2, N'4100', 0.00,  100.00);

SET @caught = 0;
BEGIN TRY
    EXEC acct.usp_PostJournalEntry
         @ClientId = @cor7, @FiscalYearId = @cor7Closed, @EntryDate = '2024-06-01',
         @Description = N'Verification - closed year', @Lines = @jeLines,
         @JournalEntryId = @jeId OUTPUT;
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
    -- An error raised inside a trigger dooms the ambient transaction. Clearing
    -- it here is what lets the next assertion run instead of the whole script
    -- dying with error 3930 on its next write.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_PostJournalEntry refuses a closed fiscal year',
       '50004', CONVERT(NVARCHAR(100), @caught)
WHERE  @caught <> 50004;

/*--- 50005: an entry date outside its fiscal year ------------------------*/
SET @caught = 0;
BEGIN TRY
    EXEC acct.usp_PostJournalEntry
         @ClientId = @cor1, @FiscalYearId = @cor1Fy2025, @EntryDate = '2023-06-01',
         @Description = N'Verification - wrong year', @Lines = @jeLines,
         @JournalEntryId = @jeId OUTPUT;
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
    -- An error raised inside a trigger dooms the ambient transaction. Clearing
    -- it here is what lets the next assertion run instead of the whole script
    -- dying with error 3930 on its next write.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_PostJournalEntry refuses a date outside the fiscal year',
       '50005', CONVERT(NVARCHAR(100), @caught)
WHERE  @caught <> 50005;

/*--- 50007: editing a line of a posted entry -----------------------------*/
DECLARE @postedLineCountBefore INT = (SELECT COUNT(*) FROM acct.JournalLine);

SET @caught = 0;
BEGIN TRY
    UPDATE acct.JournalLine
    SET    Memo = N'tampered'
    WHERE  JournalLineId = (SELECT MIN(l.JournalLineId)
                            FROM   acct.JournalLine  AS l
                            JOIN   acct.JournalEntry AS e ON e.JournalEntryId = l.JournalEntryId
                            WHERE  e.IsPosted = 1);
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
    -- An error raised inside a trigger dooms the ambient transaction. Clearing
    -- it here is what lets the next assertion run instead of the whole script
    -- dying with error 3930 on its next write.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'the trigger rejects an edit to a posted journal line',
       '50007', CONVERT(NVARCHAR(100), @caught)
WHERE  @caught <> 50007;

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'the rejected edit left no trace', '0',
       CONVERT(NVARCHAR(100), COUNT(*))
FROM   acct.JournalLine WHERE Memo = N'tampered'
HAVING COUNT(*) <> 0;

/*--- 50007 again: deleting a line of a posted entry ----------------------*/
SET @caught = 0;
BEGIN TRY
    DELETE FROM acct.JournalLine
    WHERE  JournalLineId = (SELECT MIN(l.JournalLineId)
                            FROM   acct.JournalLine  AS l
                            JOIN   acct.JournalEntry AS e ON e.JournalEntryId = l.JournalEntryId
                            WHERE  e.IsPosted = 1);
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
    -- An error raised inside a trigger dooms the ambient transaction. Clearing
    -- it here is what lets the next assertion run instead of the whole script
    -- dying with error 3930 on its next write.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'the trigger rejects a delete of a posted journal line',
       '50007', CONVERT(NVARCHAR(100), @caught)
WHERE  @caught <> 50007;

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'no journal line was lost to the rejected delete',
       CONVERT(NVARCHAR(100), @postedLineCountBefore),
       CONVERT(NVARCHAR(100), (SELECT COUNT(*) FROM acct.JournalLine))
WHERE  (SELECT COUNT(*) FROM acct.JournalLine) <> @postedLineCountBefore;

/*--- 50011: recalculating a locked tax year ------------------------------*/
DECLARE @locked2023 INT = (SELECT MIN(T1ReturnId) FROM tax.T1Return WHERE TaxYear = 2023);

SET @caught = 0;
BEGIN TRY
    EXEC tax.usp_CalculateT1 @T1ReturnId = @locked2023;
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
    -- An error raised inside a trigger dooms the ambient transaction. Clearing
    -- it here is what lets the next assertion run instead of the whole script
    -- dying with error 3930 on its next write.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_CalculateT1 refuses a locked tax year',
       '50011', CONVERT(NVARCHAR(100), @caught)
WHERE  @caught <> 50011;

/*--- 50010: a return that does not exist ---------------------------------*/
SET @caught = 0;
BEGIN TRY
    EXEC tax.usp_CalculateT1 @T1ReturnId = 999999;
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
    -- An error raised inside a trigger dooms the ambient transaction. Clearing
    -- it here is what lets the next assertion run instead of the whole script
    -- dying with error 3930 on its next write.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_CalculateT1 rejects an unknown return',
       '50010', CONVERT(NVARCHAR(100), @caught)
WHERE  @caught <> 50010;

/*--- 50020: malformed slip JSON ------------------------------------------*/
SET @caught = 0;
BEGIN TRY
    EXEC tax.usp_ImportSlips @ClientId = @scratchOn, @TaxYear = 2024,
                             @SlipsJson = N'{not valid json';
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
    -- An error raised inside a trigger dooms the ambient transaction. Clearing
    -- it here is what lets the next assertion run instead of the whole script
    -- dying with error 3930 on its next write.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_ImportSlips rejects malformed JSON',
       '50020', CONVERT(NVARCHAR(100), @caught)
WHERE  @caught <> 50020;

/*--- 50030: an overlapping GST/HST period --------------------------------*/
SET @caught = 0;
DECLARE @gstDup INT;
BEGIN TRY
    EXEC tax.usp_FileGSTHSTReturn
         @ClientId = @cor1, @PeriodStart = '2024-02-01', @PeriodEnd = '2024-04-30',
         @GSTHSTReturnId = @gstDup OUTPUT;
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
    -- An error raised inside a trigger dooms the ambient transaction. Clearing
    -- it here is what lets the next assertion run instead of the whole script
    -- dying with error 3930 on its next write.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_FileGSTHSTReturn rejects an overlapping period',
       '50030', CONVERT(NVARCHAR(100), @caught)
WHERE  @caught <> 50030;

/*--- 50060: re-running a processed pay period ----------------------------*/
DECLARE @cor1Payroll INT = (SELECT ClientId FROM client.Client WHERE ClientCode = N'COR-0001');
DECLARE @processedPeriod INT = (SELECT MIN(PayPeriodId) FROM payroll.PayPeriod
                                WHERE ClientId = @cor1Payroll AND IsProcessed = 1);

SET @caught = 0;
BEGIN TRY
    EXEC payroll.usp_RunPayroll @ClientId = @cor1Payroll, @PayPeriodId = @processedPeriod;
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
    -- An error raised inside a trigger dooms the ambient transaction. Clearing
    -- it here is what lets the next assertion run instead of the whole script
    -- dying with error 3930 on its next write.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_RunPayroll refuses to re-run a processed period without @Force',
       '50060', CONVERT(NVARCHAR(100), @caught)
WHERE  @caught <> 50060;

/*--- the batch driver reports failures rather than aborting ---------------*/
DECLARE @batch TABLE (Succeeded INT, Failed INT, Total INT);
INSERT INTO @batch
EXEC tax.usp_RecalculateAllReturns @TaxYear = 2023, @IncludeFailureDetail = 0;

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract',
       'usp_RecalculateAllReturns reports the locked year as failures, not an exception',
       CONCAT('0 succeeded / ', b.Total, ' failed'),
       CONCAT(b.Succeeded, ' succeeded / ', b.Failed, ' failed')
FROM   @batch AS b
WHERE  b.Succeeded <> 0 OR b.Failed <> b.Total OR b.Total = 0;

/*--- the batched purge is a no-op when nothing is old enough -------------*/
DECLARE @purged INT;
INSERT INTO @purgeOut
EXEC audit.usp_PurgeChangeLog @RetentionDays = 36500, @RowsDeleted = @purged OUTPUT;

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_PurgeChangeLog deletes nothing inside the retention window',
       '0', CONVERT(NVARCHAR(100), @purged)
WHERE  @purged <> 0;

/*--- the dynamic-SQL search still returns rows ---------------------------*/
DECLARE @searchResults TABLE
(
    ClientId INT, ClientCode NVARCHAR(20), ClientType CHAR(1),
    DisplayName NVARCHAR(300), ProvinceCode CHAR(2), IsActive BIT, OnboardedDate DATE
);
INSERT INTO @searchResults
EXEC client.usp_SearchClients @ProvinceCode = 'ON', @ClientType = 'I', @IsActive = 1;

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_SearchClients filters to active Ontario individuals',
       'all match', 'mismatch found'
WHERE  EXISTS (SELECT 1 FROM @searchResults
               WHERE ProvinceCode <> 'ON' OR ClientType <> 'I' OR IsActive <> 1)
   OR  NOT EXISTS (SELECT 1 FROM @searchResults);

/*--- the multi-result-set procedure describes cleanly ---------------------*/
INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'usp_GenerateClientYearEndPackage returns a describable result set',
       'yes', 'no'
WHERE  NOT EXISTS (
    SELECT 1
    FROM   sys.dm_exec_describe_first_result_set(
               N'EXEC tax.usp_GenerateClientYearEndPackage @ClientId = 1, @TaxYear = 2024',
               NULL, 0)
    WHERE  error_number IS NULL);

/*--- clean up the scratch clients ----------------------------------------
  These cascade to their addresses, contacts, invoices and invoice lines.
  None of them carries a posted journal line, so the immutability trigger
  does not block the delete.
--------------------------------------------------------------------------*/
DELETE FROM client.Client
WHERE  ClientCode IN (N'VERIFY-ON', N'VERIFY-AB', N'VERIFY-VIEW');

INSERT INTO #Failures (Category, Assertion, Expected, Actual)
SELECT 'contract', 'scratch clients cleaned up', '25',
       CONVERT(NVARCHAR(100), COUNT(*))
FROM   client.Client
HAVING COUNT(*) <> 25;
GO

/*==============================================================================
  5. RESULT
==============================================================================*/
PRINT '';

IF EXISTS (SELECT 1 FROM #Failures)
BEGIN
    SELECT Seq, Category, Assertion, Expected, Actual
    FROM   #Failures
    ORDER  BY Seq;

    DECLARE @n INT = (SELECT COUNT(*) FROM #Failures);
    DECLARE @msg NVARCHAR(200) = CONCAT(N'VERIFICATION FAILED: ', @n, N' assertion(s) did not hold.');
    THROW 50999, @msg, 1;
END
ELSE
BEGIN
    PRINT 'VERIFICATION PASSED - all assertions hold.';
    PRINT '';
    PRINT '  39 tables   9 views (1 indexed)   20 functions   12 procedures   4 triggers';
    PRINT '  1 sequence  3 table types         1 synonym      10 filtered indexes';
    PRINT '  18 computed columns across 7 schemas';
END

DROP TABLE IF EXISTS #Failures;
GO
