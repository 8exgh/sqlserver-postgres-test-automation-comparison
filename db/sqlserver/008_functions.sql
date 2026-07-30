/*==============================================================================
  008 - Functions

  Three flavours, deliberately:
    scalar      - pure validators and rate calculations
    inline TVF  - single SELECT, expanded into the calling query
    multi-stmt  - a declared return table filled procedurally

  All are WITH SCHEMABINDING. For the pure ones that also makes them
  deterministic (so they could be indexed); for the rest it is what allows the
  indexed view in 009 to exist and stops the underlying tables being altered
  out from under them.
==============================================================================*/
USE CdnTaxPractice;
GO

/*------------------------------------------------------------------------------
  Drop the composed functions before recreating them.

  CREATE OR ALTER is not enough here. Three of these functions are called by
  other WITH SCHEMABINDING functions, and schema binding is exactly the promise
  that the callee will not change underneath the caller - so ALTER on the callee
  fails with error 3729 while the caller exists. Re-running this file therefore
  has to drop dependents before their dependencies.

  Only the composed chains need this; the standalone functions below are left to
  CREATE OR ALTER as normal.
------------------------------------------------------------------------------*/
DROP FUNCTION IF EXISTS tax.fn_IsValidSIN;             -- calls util.fn_PassesLuhn
GO
DROP FUNCTION IF EXISTS tax.fn_IsValidBusinessNumber;  -- calls util.fn_PassesLuhn
GO
DROP FUNCTION IF EXISTS util.fn_PassesLuhn;
GO
DROP FUNCTION IF EXISTS tax.fn_FederalTax;             -- calls tax.fn_BracketTax
GO
DROP FUNCTION IF EXISTS tax.fn_ProvincialTax;          -- calls tax.fn_BracketTax
GO
DROP FUNCTION IF EXISTS tax.fn_BracketTax;
GO
DROP FUNCTION IF EXISTS ref.fn_SalesTaxRate;           -- calls the two below
GO
DROP FUNCTION IF EXISTS ref.fn_GSTHSTRate;
GO
DROP FUNCTION IF EXISTS ref.fn_PSTRate;
GO

/*==============================================================================
  SCALAR - identifier validation
==============================================================================*/

/*--------------------------------------------------------------------------
  Luhn (mod-10) check, digits doubled from the right. Shared by the SIN and
  Business Number validators, which differ only in their format rules.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION util.fn_PassesLuhn (@Digits VARCHAR(20))
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    IF @Digits IS NULL OR LEN(@Digits) < 2
        RETURN 0;

    DECLARE @sum        INT = 0,
            @pos        INT = LEN(@Digits),
            @fromRight  INT = 1,
            @digit      INT;

    WHILE @pos >= 1
    BEGIN
        SET @digit = ASCII(SUBSTRING(@Digits, @pos, 1)) - 48;
        IF @digit < 0 OR @digit > 9
            RETURN 0;                       -- non-numeric character

        -- Every second digit counting from the right is doubled.
        IF @fromRight % 2 = 0
        BEGIN
            SET @digit = @digit * 2;
            IF @digit > 9
                SET @digit = @digit - 9;
        END

        SET @sum       = @sum + @digit;
        SET @pos       = @pos - 1;
        SET @fromRight = @fromRight + 1;
    END

    RETURN CASE WHEN @sum % 10 = 0 THEN 1 ELSE 0 END;
END
GO

/*--------------------------------------------------------------------------
  Social Insurance Number: nine digits with a Luhn check digit.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION tax.fn_IsValidSIN (@SIN CHAR(9))
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    IF @SIN IS NULL OR @SIN NOT LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
        RETURN 0;

    RETURN util.fn_PassesLuhn(@SIN);
END
GO

/*--------------------------------------------------------------------------
  Business Number. Accepts either the bare nine-digit registrant number or the
  full fifteen-character account form, e.g. 123456789RT0001.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION tax.fn_IsValidBusinessNumber (@BusinessNumber VARCHAR(15))
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    IF @BusinessNumber IS NULL
        RETURN 0;

    DECLARE @bn VARCHAR(15) = REPLACE(@BusinessNumber, ' ', '');

    IF LEN(@bn) = 15
    BEGIN
        -- Program identifier: RT = GST/HST, RP = payroll, RC = corporate tax,
        -- RM = import/export. Followed by a four-digit account reference.
        IF SUBSTRING(@bn, 10, 2) NOT IN ('RT', 'RP', 'RC', 'RM')
            RETURN 0;
        IF SUBSTRING(@bn, 12, 4) NOT LIKE '[0-9][0-9][0-9][0-9]'
            RETURN 0;
        SET @bn = LEFT(@bn, 9);
    END

    IF @bn NOT LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
        RETURN 0;

    RETURN util.fn_PassesLuhn(@bn);
END
GO

/*==============================================================================
  SCALAR - income tax
==============================================================================*/

/*--------------------------------------------------------------------------
  Progressive tax for any jurisdiction. Each bracket contributes
  (min(income, upper) - lower) * rate for the portion of income above its
  lower bound; the top bracket has a NULL upper bound.

  fn_FederalTax and fn_ProvincialTax are thin wrappers so callers never have
  to know that the federal jurisdiction code is 'CA'.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION tax.fn_BracketTax
(
    @JurisdictionCode CHAR(2),
    @TaxYear          SMALLINT,
    @TaxableIncome    DECIMAL(19, 2)
)
RETURNS DECIMAL(19, 2)
WITH SCHEMABINDING
AS
BEGIN
    IF @TaxableIncome IS NULL OR @TaxableIncome <= 0
        RETURN 0;

    DECLARE @tax DECIMAL(29, 8);

    SELECT @tax = SUM(
               (CASE WHEN b.UpperBound IS NOT NULL AND @TaxableIncome > b.UpperBound
                     THEN b.UpperBound
                     ELSE @TaxableIncome
                END - b.LowerBound) * b.Rate)
    FROM   ref.TaxBracket AS b
    WHERE  b.JurisdictionCode = @JurisdictionCode
      AND  b.TaxYear          = @TaxYear
      AND  @TaxableIncome     > b.LowerBound;

    RETURN CONVERT(DECIMAL(19, 2), ROUND(ISNULL(@tax, 0), 2));
END
GO

CREATE OR ALTER FUNCTION tax.fn_FederalTax
(
    @TaxYear       SMALLINT,
    @TaxableIncome DECIMAL(19, 2)
)
RETURNS DECIMAL(19, 2)
WITH SCHEMABINDING
AS
BEGIN
    RETURN tax.fn_BracketTax('CA', @TaxYear, @TaxableIncome);
END
GO

CREATE OR ALTER FUNCTION tax.fn_ProvincialTax
(
    @ProvinceCode  CHAR(2),
    @TaxYear       SMALLINT,
    @TaxableIncome DECIMAL(19, 2)
)
RETURNS DECIMAL(19, 2)
WITH SCHEMABINDING
AS
BEGIN
    RETURN tax.fn_BracketTax(@ProvinceCode, @TaxYear, @TaxableIncome);
END
GO

/*--------------------------------------------------------------------------
  Combined federal + provincial marginal rate: the rate that would apply to
  one more dollar of taxable income.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION tax.fn_MarginalRate
(
    @ProvinceCode  CHAR(2),
    @TaxYear       SMALLINT,
    @TaxableIncome DECIMAL(19, 2)
)
RETURNS DECIMAL(9, 6)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @income DECIMAL(19, 2) = CASE WHEN @TaxableIncome < 0 OR @TaxableIncome IS NULL
                                          THEN 0 ELSE @TaxableIncome END;
    DECLARE @federal DECIMAL(9, 6), @provincial DECIMAL(9, 6);

    SELECT @federal = b.Rate
    FROM   ref.TaxBracket AS b
    WHERE  b.TaxYear = @TaxYear
      AND  b.JurisdictionCode = 'CA'
      AND  @income >= b.LowerBound
      AND  (b.UpperBound IS NULL OR @income < b.UpperBound);

    SELECT @provincial = b.Rate
    FROM   ref.TaxBracket AS b
    WHERE  b.TaxYear = @TaxYear
      AND  b.JurisdictionCode = @ProvinceCode
      AND  @income >= b.LowerBound
      AND  (b.UpperBound IS NULL OR @income < b.UpperBound);

    RETURN ISNULL(@federal, 0) + ISNULL(@provincial, 0);
END
GO

/*==============================================================================
  SCALAR - payroll
==============================================================================*/

/*--------------------------------------------------------------------------
  CPP base contribution: (pensionable earnings capped at the YMPE, less the
  basic exemption) at the year's contribution rate.

  This is the *annual* formula. Real per-period payroll prorates the basic
  exemption across pay periods; applying the annual formula to cumulative
  earnings (as payroll.usp_RunPayroll does) instead absorbs the whole
  exemption in the first period. The annual total for a full year of
  employment is identical either way, which is what matters for a fixture -
  but the period-by-period split differs from a CRA payroll calculation.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION tax.fn_CPPContribution
(
    @TaxYear              SMALLINT,
    @PensionableEarnings  DECIMAL(19, 2)
)
RETURNS DECIMAL(19, 2)
WITH SCHEMABINDING
AS
BEGIN
    IF @PensionableEarnings IS NULL OR @PensionableEarnings <= 0
        RETURN 0;

    DECLARE @rate      DECIMAL(9, 6),
            @exemption DECIMAL(19, 2),
            @ympe      DECIMAL(19, 2);

    SELECT @rate      = p.CPPRate,
           @exemption = p.CPPBasicExemption,
           @ympe      = p.YMPE
    FROM   ref.PayrollRate AS p
    WHERE  p.TaxYear = @TaxYear;

    IF @rate IS NULL
        RETURN 0;                           -- no parameters loaded for the year

    DECLARE @contributory DECIMAL(19, 2) =
        (CASE WHEN @PensionableEarnings > @ympe THEN @ympe ELSE @PensionableEarnings END)
        - @exemption;

    IF @contributory <= 0
        RETURN 0;

    RETURN CONVERT(DECIMAL(19, 2), ROUND(@contributory * @rate, 2));
END
GO

/*--------------------------------------------------------------------------
  CPP2: the second additional contribution on earnings between the YMPE and
  the YAMPE. Returns zero for years before it existed (YAMPE seeded as 0).
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION tax.fn_CPP2Contribution
(
    @TaxYear             SMALLINT,
    @PensionableEarnings DECIMAL(19, 2)
)
RETURNS DECIMAL(19, 2)
WITH SCHEMABINDING
AS
BEGIN
    IF @PensionableEarnings IS NULL OR @PensionableEarnings <= 0
        RETURN 0;

    DECLARE @rate  DECIMAL(9, 6),
            @ympe  DECIMAL(19, 2),
            @yampe DECIMAL(19, 2);

    SELECT @rate  = p.CPP2Rate,
           @ympe  = p.YMPE,
           @yampe = p.YAMPE
    FROM   ref.PayrollRate AS p
    WHERE  p.TaxYear = @TaxYear;

    IF @rate IS NULL OR @rate = 0 OR @yampe IS NULL OR @yampe <= @ympe
        RETURN 0;

    IF @PensionableEarnings <= @ympe
        RETURN 0;

    DECLARE @contributory DECIMAL(19, 2) =
        (CASE WHEN @PensionableEarnings > @yampe THEN @yampe ELSE @PensionableEarnings END)
        - @ympe;

    RETURN CONVERT(DECIMAL(19, 2), ROUND(@contributory * @rate, 2));
END
GO

/*--------------------------------------------------------------------------
  EI premium. Quebec has its own (lower) rate because QPIP covers parental
  benefits separately.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION tax.fn_EIPremium
(
    @TaxYear            SMALLINT,
    @InsurableEarnings  DECIMAL(19, 2),
    @ProvinceCode       CHAR(2)
)
RETURNS DECIMAL(19, 2)
WITH SCHEMABINDING
AS
BEGIN
    IF @InsurableEarnings IS NULL OR @InsurableEarnings <= 0
        RETURN 0;

    DECLARE @rate DECIMAL(9, 6), @mie DECIMAL(19, 2);

    SELECT @rate = CASE WHEN @ProvinceCode = 'QC' THEN p.EIRateQuebec ELSE p.EIRate END,
           @mie  = p.EIMaxInsurableEarnings
    FROM   ref.PayrollRate AS p
    WHERE  p.TaxYear = @TaxYear;

    IF @rate IS NULL
        RETURN 0;

    DECLARE @insurable DECIMAL(19, 2) =
        CASE WHEN @InsurableEarnings > @mie THEN @mie ELSE @InsurableEarnings END;

    RETURN CONVERT(DECIMAL(19, 2), ROUND(@insurable * @rate, 2));
END
GO

/*==============================================================================
  SCALAR - sales tax
==============================================================================*/

/*--------------------------------------------------------------------------
  The GST/HST portion only - what a registrant collects and remits to the CRA.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION ref.fn_GSTHSTRate
(
    @ProvinceCode CHAR(2),
    @AsOfDate     DATE
)
RETURNS DECIMAL(9, 5)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @rate DECIMAL(9, 5);

    SELECT @rate = r.GSTRate + r.HSTRate
    FROM   ref.SalesTaxRate AS r
    WHERE  r.ProvinceCode  = @ProvinceCode
      AND  r.EffectiveFrom <= @AsOfDate
      AND  (r.EffectiveTo IS NULL OR r.EffectiveTo > @AsOfDate);

    RETURN ISNULL(@rate, 0);
END
GO

/*--------------------------------------------------------------------------
  The provincial portion (PST, or QST in Quebec), which is remitted to the
  province rather than to the CRA.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION ref.fn_PSTRate
(
    @ProvinceCode CHAR(2),
    @AsOfDate     DATE
)
RETURNS DECIMAL(9, 5)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @rate DECIMAL(9, 5);

    SELECT @rate = r.PSTRate + r.QSTRate
    FROM   ref.SalesTaxRate AS r
    WHERE  r.ProvinceCode  = @ProvinceCode
      AND  r.EffectiveFrom <= @AsOfDate
      AND  (r.EffectiveTo IS NULL OR r.EffectiveTo > @AsOfDate);

    RETURN ISNULL(@rate, 0);
END
GO

CREATE OR ALTER FUNCTION ref.fn_SalesTaxRate
(
    @ProvinceCode CHAR(2),
    @AsOfDate     DATE
)
RETURNS DECIMAL(9, 5)
WITH SCHEMABINDING
AS
BEGIN
    RETURN ref.fn_GSTHSTRate(@ProvinceCode, @AsOfDate)
         + ref.fn_PSTRate(@ProvinceCode, @AsOfDate);
END
GO

/*==============================================================================
  SCALAR - accounting and dates
==============================================================================*/

/*--------------------------------------------------------------------------
  Balance of a single account as at a date, signed by the account type's
  normal balance so an asset and a liability both read as positive when they
  are in their expected direction. Only posted entries count.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION acct.fn_AccountBalance
(
    @AccountId INT,
    @AsOfDate  DATE
)
RETURNS DECIMAL(19, 2)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @debits  DECIMAL(19, 2),
            @credits DECIMAL(19, 2),
            @normal  CHAR(1);

    SELECT @normal = t.NormalBalance
    FROM   acct.Account       AS a
    JOIN   ref.AccountType    AS t ON t.AccountTypeCode = a.AccountTypeCode
    WHERE  a.AccountId = @AccountId;

    IF @normal IS NULL
        RETURN 0;

    SELECT @debits  = ISNULL(SUM(l.DebitAmount), 0),
           @credits = ISNULL(SUM(l.CreditAmount), 0)
    FROM   acct.JournalLine  AS l
    JOIN   acct.JournalEntry AS e ON e.JournalEntryId = l.JournalEntryId
    WHERE  l.AccountId  = @AccountId
      AND  e.IsPosted   = 1
      AND  e.EntryDate <= @AsOfDate;

    RETURN CASE WHEN @normal = 'D'
                THEN ISNULL(@debits, 0)  - ISNULL(@credits, 0)
                ELSE ISNULL(@credits, 0) - ISNULL(@debits, 0)
           END;
END
GO

/*--------------------------------------------------------------------------
  Business days in [@FromDate, @ToDate), excluding weekends and statutory
  holidays for the given jurisdiction (national holidays always count).

  Weekend detection uses DATEDIFF from a known Monday rather than
  DATEPART(WEEKDAY, ...), which depends on the session's SET DATEFIRST and
  would therefore give different answers to different callers.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION util.fn_BusinessDaysBetween
(
    @FromDate         DATE,
    @ToDate           DATE,
    @JurisdictionCode CHAR(2)
)
RETURNS INT
WITH SCHEMABINDING
AS
BEGIN
    IF @FromDate IS NULL OR @ToDate IS NULL OR @ToDate <= @FromDate
        RETURN 0;

    DECLARE @days     INT  = 0,
            @cursor   DATE = @FromDate,
            @dow      INT;

    WHILE @cursor < @ToDate
    BEGIN
        -- 1900-01-01 was a Monday, so 0 = Monday ... 5 = Saturday, 6 = Sunday.
        SET @dow = DATEDIFF(DAY, '19000101', @cursor) % 7;

        IF @dow < 5
           AND NOT EXISTS (SELECT 1
                           FROM   ref.StatutoryHoliday AS h
                           WHERE  h.HolidayDate = @cursor
                             AND  h.JurisdictionCode IN ('CA', @JurisdictionCode))
            SET @days = @days + 1;

        SET @cursor = DATEADD(DAY, 1, @cursor);
    END

    RETURN @days;
END
GO

/*==============================================================================
  INLINE TABLE-VALUED FUNCTIONS
==============================================================================*/

/*--------------------------------------------------------------------------
  One row per bracket showing how much income fell in it and the tax that
  produced. Summing TaxInBracket must equal tax.fn_BracketTax for the same
  arguments - 099_verify.sql asserts exactly that.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION tax.fn_TaxBracketBreakdown
(
    @JurisdictionCode CHAR(2),
    @TaxYear          SMALLINT,
    @TaxableIncome    DECIMAL(19, 2)
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT b.Ordinal,
           b.LowerBound,
           b.UpperBound,
           b.Rate,
           CONVERT(DECIMAL(19, 2),
               (CASE WHEN b.UpperBound IS NOT NULL AND @TaxableIncome > b.UpperBound
                     THEN b.UpperBound
                     ELSE @TaxableIncome
                END - b.LowerBound))                              AS IncomeInBracket,
           CONVERT(DECIMAL(19, 2), ROUND(
               (CASE WHEN b.UpperBound IS NOT NULL AND @TaxableIncome > b.UpperBound
                     THEN b.UpperBound
                     ELSE @TaxableIncome
                END - b.LowerBound) * b.Rate, 2))                 AS TaxInBracket,
           SUM(CONVERT(DECIMAL(19, 2), ROUND(
               (CASE WHEN b.UpperBound IS NOT NULL AND @TaxableIncome > b.UpperBound
                     THEN b.UpperBound
                     ELSE @TaxableIncome
                END - b.LowerBound) * b.Rate, 2)))
               OVER (ORDER BY b.Ordinal
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CumulativeTax
    FROM   ref.TaxBracket AS b
    WHERE  b.JurisdictionCode = @JurisdictionCode
      AND  b.TaxYear          = @TaxYear
      AND  @TaxableIncome     > b.LowerBound
);
GO

/*--------------------------------------------------------------------------
  Slip amounts rolled up into the income lines they feed on a T1. This is what
  makes the box/definition mapping in ref.SlipBoxDefinition earn its keep: a
  T4 box 14 and a T4A box 020 both land in the right place without the caller
  knowing either box number.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION tax.fn_ClientSlipTotals
(
    @ClientId INT,
    @TaxYear  SMALLINT
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT ISNULL(SUM(CASE WHEN d.IncomeCategory = 'Employment'     THEN sb.Amount END), 0) AS EmploymentIncome,
           ISNULL(SUM(CASE WHEN d.IncomeCategory = 'Investment'     THEN sb.Amount END), 0) AS InvestmentIncome,
           ISNULL(SUM(CASE WHEN d.IncomeCategory = 'SelfEmployment' THEN sb.Amount END), 0) AS SelfEmploymentIncome,
           ISNULL(SUM(CASE WHEN d.IncomeCategory = 'Pension'        THEN sb.Amount END), 0) AS PensionIncome,
           ISNULL(SUM(CASE WHEN d.IncomeCategory = 'Other'          THEN sb.Amount END), 0) AS OtherIncome,
           ISNULL(SUM(CASE WHEN d.IncomeCategory = 'Deduction'      THEN sb.Amount END), 0) AS Deductions,
           ISNULL(SUM(CASE WHEN d.IncomeCategory = 'TaxWithheld'    THEN sb.Amount END), 0) AS TaxWithheld,
           ISNULL(SUM(CASE WHEN d.IncomeCategory = 'CPP'            THEN sb.Amount END), 0) AS CPPContributions,
           ISNULL(SUM(CASE WHEN d.IncomeCategory = 'EI'             THEN sb.Amount END), 0) AS EIPremiums,
           COUNT_BIG(DISTINCT s.SlipId)                                                     AS SlipCount
    FROM   tax.Slip              AS s
    JOIN   tax.SlipBox           AS sb ON sb.SlipId = s.SlipId
    JOIN   ref.SlipBoxDefinition AS d  ON d.SlipTypeCode = sb.SlipTypeCode
                                      AND d.BoxNumber    = sb.BoxNumber
    WHERE  s.ClientId = @ClientId
      AND  s.TaxYear  = @TaxYear
);
GO

/*--------------------------------------------------------------------------
  Outstanding receivables bucketed by age. Returns only invoices with a
  positive balance so the caller does not have to filter.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION acct.fn_InvoiceAging (@AsOfDate DATE)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT i.InvoiceId,
           i.InvoiceNumber,
           i.ClientId,
           i.InvoiceDate,
           i.DueDate,
           i.Total,
           i.Total - ISNULL(p.AmountPaid, 0)          AS OutstandingAmount,
           DATEDIFF(DAY, i.DueDate, @AsOfDate)        AS DaysOverdue,
           CASE WHEN DATEDIFF(DAY, i.DueDate, @AsOfDate) <= 0  THEN 'Current'
                WHEN DATEDIFF(DAY, i.DueDate, @AsOfDate) <= 30 THEN '1-30'
                WHEN DATEDIFF(DAY, i.DueDate, @AsOfDate) <= 60 THEN '31-60'
                WHEN DATEDIFF(DAY, i.DueDate, @AsOfDate) <= 90 THEN '61-90'
                ELSE '90+'
           END                                        AS AgingBucket
    FROM   acct.Invoice AS i
    OUTER APPLY
    (
        SELECT SUM(pay.Amount) AS AmountPaid
        FROM   acct.Payment AS pay
        WHERE  pay.InvoiceId    = i.InvoiceId
          AND  pay.PaymentDate <= @AsOfDate
    ) AS p
    WHERE  i.Status IN (N'Sent', N'PartiallyPaid')
      AND  i.InvoiceDate <= @AsOfDate
      AND  i.Total - ISNULL(p.AmountPaid, 0) > 0
);
GO

/*==============================================================================
  MULTI-STATEMENT TABLE-VALUED FUNCTIONS
==============================================================================*/

/*--------------------------------------------------------------------------
  Trial balance for a fiscal year as at a date. Multi-statement because the
  final row is a total line that has to be appended after the per-account
  aggregate is known.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION acct.fn_TrialBalance
(
    @ClientId     INT,
    @FiscalYearId INT,
    @AsOfDate     DATE
)
RETURNS @TrialBalance TABLE
(
    AccountId       INT            NULL,
    AccountNumber   NVARCHAR(20)   NOT NULL,
    AccountName     NVARCHAR(100)  NOT NULL,
    AccountTypeCode NVARCHAR(20)   NULL,
    NormalBalance   CHAR(1)        NULL,
    TotalDebits     DECIMAL(19, 2) NOT NULL,
    TotalCredits    DECIMAL(19, 2) NOT NULL,
    Balance         DECIMAL(19, 2) NOT NULL,
    IsTotalRow      BIT            NOT NULL
)
WITH SCHEMABINDING
AS
BEGIN
    INSERT INTO @TrialBalance
        (AccountId, AccountNumber, AccountName, AccountTypeCode,
         NormalBalance, TotalDebits, TotalCredits, Balance, IsTotalRow)
    SELECT a.AccountId,
           a.AccountNumber,
           a.AccountName,
           a.AccountTypeCode,
           t.NormalBalance,
           SUM(l.DebitAmount),
           SUM(l.CreditAmount),
           CASE WHEN t.NormalBalance = 'D'
                THEN SUM(l.DebitAmount)  - SUM(l.CreditAmount)
                ELSE SUM(l.CreditAmount) - SUM(l.DebitAmount)
           END,
           0
    FROM   acct.Account      AS a
    JOIN   ref.AccountType   AS t ON t.AccountTypeCode = a.AccountTypeCode
    JOIN   acct.JournalLine  AS l ON l.AccountId = a.AccountId
    JOIN   acct.JournalEntry AS e ON e.JournalEntryId = l.JournalEntryId
    WHERE  a.ClientId      = @ClientId
      AND  e.FiscalYearId  = @FiscalYearId
      AND  e.IsPosted      = 1
      AND  e.EntryDate    <= @AsOfDate
    GROUP BY a.AccountId, a.AccountNumber, a.AccountName,
             a.AccountTypeCode, t.NormalBalance;

    -- The total row: in a balanced ledger the two columns must be equal, which
    -- is what makes this function a useful assertion target.
    INSERT INTO @TrialBalance
        (AccountId, AccountNumber, AccountName, AccountTypeCode,
         NormalBalance, TotalDebits, TotalCredits, Balance, IsTotalRow)
    SELECT NULL,
           N'ZZZZ',
           N'TOTAL',
           NULL,
           NULL,
           ISNULL(SUM(tb.TotalDebits), 0),
           ISNULL(SUM(tb.TotalCredits), 0),
           ISNULL(SUM(tb.TotalDebits), 0) - ISNULL(SUM(tb.TotalCredits), 0),
           1
    FROM   @TrialBalance AS tb
    WHERE  tb.IsTotalRow = 0;

    RETURN;
END
GO

/*--------------------------------------------------------------------------
  Walks the chart of accounts from a root (or from every top-level account
  when @RootAccountId is NULL), returning depth and a materialized path.

  SortPath is the account-number path, which sorts the tree into the order a
  human expects to read it in.
--------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION acct.fn_AccountHierarchy
(
    @ClientId      INT,
    @RootAccountId INT
)
RETURNS @Hierarchy TABLE
(
    AccountId       INT            NOT NULL PRIMARY KEY,
    ParentAccountId INT            NULL,
    AccountNumber   NVARCHAR(20)   NOT NULL,
    AccountName     NVARCHAR(100)  NOT NULL,
    AccountTypeCode NVARCHAR(20)   NOT NULL,
    Depth           INT            NOT NULL,
    NamePath        NVARCHAR(4000) NOT NULL,
    SortPath        NVARCHAR(4000) NOT NULL
)
WITH SCHEMABINDING
AS
BEGIN
    WITH Tree AS
    (
        SELECT a.AccountId,
               a.ParentAccountId,
               a.AccountNumber,
               a.AccountName,
               a.AccountTypeCode,
               0                                            AS Depth,
               CONVERT(NVARCHAR(4000), a.AccountName)       AS NamePath,
               CONVERT(NVARCHAR(4000), a.AccountNumber)     AS SortPath
        FROM   acct.Account AS a
        WHERE  a.ClientId = @ClientId
          AND  ((@RootAccountId IS NULL AND a.ParentAccountId IS NULL)
             OR (a.AccountId = @RootAccountId))

        UNION ALL

        SELECT child.AccountId,
               child.ParentAccountId,
               child.AccountNumber,
               child.AccountName,
               child.AccountTypeCode,
               parent.Depth + 1,
               CONVERT(NVARCHAR(4000), parent.NamePath + N' > ' + child.AccountName),
               CONVERT(NVARCHAR(4000), parent.SortPath + N'.'   + child.AccountNumber)
        FROM   acct.Account AS child
        JOIN   Tree         AS parent ON parent.AccountId = child.ParentAccountId
        WHERE  child.ClientId = @ClientId
    )
    INSERT INTO @Hierarchy
        (AccountId, ParentAccountId, AccountNumber, AccountName,
         AccountTypeCode, Depth, NamePath, SortPath)
    SELECT AccountId, ParentAccountId, AccountNumber, AccountName,
           AccountTypeCode, Depth, NamePath, SortPath
    FROM   Tree;

    RETURN;
END
GO

PRINT '008 functions ready.';
GO
