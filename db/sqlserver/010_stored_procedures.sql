/*==============================================================================
  010 - Stored procedures

  ---------------------------------------------------------------------------
  A NOTE ON XACT_ABORT

  These procedures deliberately do NOT set XACT_ABORT ON at the top. With it
  on for the whole body, a *validation* THROW - raised before anything has
  been written - dooms the caller's ambient transaction. The caller can still
  catch the error, but its next write then fails with error 3930, so a batch
  driver looping over many items cannot record the failure and carry on.

  Instead the pattern here is:
      validate (plain THROW, transaction stays committable)
      SET XACT_ABORT ON
      BEGIN TRANSACTION ... COMMIT
  so only genuine write failures abort the transaction. XACT_ABORT reverts to
  its previous value when the procedure returns.

  Two procedures never set it at all - acct.usp_PostJournalEntry and
  acct.usp_CloseFiscalYear - because XACT_ABORT ON dooms a transaction, and a
  doomed transaction cannot be rolled back to a savepoint. That would defeat
  the nested-call design where CloseFiscalYear calls PostJournalEntry inside
  its own transaction.
  ---------------------------------------------------------------------------

  Error numbers raised by THROW, so a test harness can assert on them rather
  than on message text:

    50001  journal entry does not balance
    50002  unknown account number on a journal line
    50003  posting attempted to a control account
    50004  fiscal year is closed
    50005  entry date outside its fiscal year
    50006  journal entry has no lines
    50010  T1 return not found
    50011  tax year is locked
    50020  malformed slip JSON
    50021  unknown client
    50030  overlapping GST/HST period already filed
    50040  invalid SIN
    50041  invalid business number
    50042  client type / field mismatch
    50050  invoice has no lines
    50060  pay period already processed
==============================================================================*/
USE CdnTaxPractice;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/*==============================================================================
  client.usp_UpsertClient

  MERGE-based insert-or-update keyed on the natural key (ClientCode), with the
  identifier validators applied before anything is written.
==============================================================================*/
CREATE OR ALTER PROCEDURE client.usp_UpsertClient
(
    @ClientCode         NVARCHAR(20),
    @ClientType         CHAR(1),
    @ProvinceCode       CHAR(2),
    @OnboardedDate      DATE           = NULL,
    -- individuals
    @FirstName          NVARCHAR(50)   = NULL,
    @LastName           NVARCHAR(50)   = NULL,
    @DateOfBirth        DATE           = NULL,
    @SIN                CHAR(9)        = NULL,
    @MaritalStatus      NVARCHAR(20)   = NULL,
    -- corporations
    @LegalName          NVARCHAR(150)  = NULL,
    @IncorporationDate  DATE           = NULL,
    @BusinessNumber     CHAR(9)        = NULL,
    @FiscalYearEndMonth TINYINT        = NULL,
    @IsActive           BIT            = 1,
    @ClientId           INT            OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    SET @OnboardedDate = ISNULL(@OnboardedDate, CONVERT(DATE, SYSUTCDATETIME()));

    BEGIN TRY
        /*--- validation before any write --------------------------------*/
        IF @ClientType NOT IN ('I', 'C')
            THROW 50042, 'ClientType must be I (individual) or C (corporation).', 1;

        IF @ClientType = 'I' AND (@FirstName IS NULL OR @LastName IS NULL OR @DateOfBirth IS NULL)
            THROW 50042, 'An individual client requires FirstName, LastName and DateOfBirth.', 1;

        IF @ClientType = 'C' AND (@LegalName IS NULL OR @IncorporationDate IS NULL
                                  OR @FiscalYearEndMonth IS NULL)
            THROW 50042, 'A corporate client requires LegalName, IncorporationDate and FiscalYearEndMonth.', 1;

        IF @SIN IS NOT NULL AND tax.fn_IsValidSIN(@SIN) = 0
            THROW 50040, 'SIN failed the mod-10 check digit test.', 1;

        IF @BusinessNumber IS NOT NULL AND tax.fn_IsValidBusinessNumber(@BusinessNumber) = 0
            THROW 50041, 'Business Number failed the mod-10 check digit test.', 1;

        -- Null out the fields that do not apply, so the caller cannot smuggle
        -- corporate values onto an individual and trip CK_Client_TypeShape.
        IF @ClientType = 'I'
        BEGIN
            SET @LegalName = NULL; SET @IncorporationDate = NULL;
            SET @BusinessNumber = NULL; SET @FiscalYearEndMonth = NULL;
        END
        ELSE
        BEGIN
            SET @FirstName = NULL; SET @LastName = NULL;
            SET @DateOfBirth = NULL; SET @SIN = NULL; SET @MaritalStatus = NULL;
        END

        DECLARE @touched TABLE (ClientId INT NOT NULL, Action NVARCHAR(10) NOT NULL);

        -- Writes begin here; see the note at the top of this file.
        SET XACT_ABORT ON;

        BEGIN TRANSACTION;

        MERGE client.Client WITH (HOLDLOCK) AS tgt
        USING (SELECT @ClientCode AS ClientCode) AS src
              ON tgt.ClientCode = src.ClientCode
        WHEN MATCHED THEN
            UPDATE SET ClientType         = @ClientType,
                       FirstName          = @FirstName,
                       LastName           = @LastName,
                       DateOfBirth        = @DateOfBirth,
                       SIN                = @SIN,
                       MaritalStatus      = @MaritalStatus,
                       LegalName          = @LegalName,
                       IncorporationDate  = @IncorporationDate,
                       BusinessNumber     = @BusinessNumber,
                       FiscalYearEndMonth = @FiscalYearEndMonth,
                       ProvinceCode       = @ProvinceCode,
                       IsActive           = @IsActive,
                       UpdatedAt          = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (ClientCode, ClientType, FirstName, LastName, DateOfBirth, SIN,
                    MaritalStatus, LegalName, IncorporationDate, BusinessNumber,
                    FiscalYearEndMonth, ProvinceCode, OnboardedDate, IsActive)
            VALUES (@ClientCode, @ClientType, @FirstName, @LastName, @DateOfBirth, @SIN,
                    @MaritalStatus, @LegalName, @IncorporationDate, @BusinessNumber,
                    @FiscalYearEndMonth, @ProvinceCode, @OnboardedDate, @IsActive)
        OUTPUT inserted.ClientId, $action INTO @touched (ClientId, Action);

        SELECT @ClientId = ClientId FROM @touched;

        COMMIT TRANSACTION;

        SELECT ClientId, Action AS MergeAction FROM @touched;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/*==============================================================================
  client.usp_SearchClients

  Optional filters built into a dynamic statement. The predicate text is
  assembled from constants only; every user value travels as a parameter to
  sp_executesql, and the sort column is resolved against a whitelist, so no
  caller input is ever concatenated into the SQL.
==============================================================================*/
CREATE OR ALTER PROCEDURE client.usp_SearchClients
(
    @NameContains  NVARCHAR(100) = NULL,
    @ProvinceCode  CHAR(2)       = NULL,
    @ClientType    CHAR(1)       = NULL,
    @IsActive      BIT           = NULL,
    @OnboardedFrom DATE          = NULL,
    @SortColumn    SYSNAME       = N'DisplayName',
    @SortDirection NVARCHAR(4)   = N'ASC',
    @MaxRows       INT           = 100
)
AS
BEGIN
    SET NOCOUNT ON;

    -- Whitelist: anything unrecognised falls back to the default ordering.
    DECLARE @orderBy NVARCHAR(200) =
        CASE @SortColumn
             WHEN N'DisplayName'   THEN N'c.DisplayName'
             WHEN N'ClientCode'    THEN N'c.ClientCode'
             WHEN N'OnboardedDate' THEN N'c.OnboardedDate'
             WHEN N'ProvinceCode'  THEN N'c.ProvinceCode'
             ELSE N'c.DisplayName'
        END
        + CASE WHEN @SortDirection = N'DESC' THEN N' DESC' ELSE N' ASC' END;

    DECLARE @sql NVARCHAR(MAX) = N'
        SELECT TOP (@pMaxRows)
               c.ClientId, c.ClientCode, c.ClientType, c.DisplayName,
               c.ProvinceCode, c.IsActive, c.OnboardedDate
        FROM   client.Client AS c
        WHERE  1 = 1';

    IF @NameContains IS NOT NULL
        SET @sql += N' AND c.DisplayName LIKE N''%'' + @pNameContains + N''%''';
    IF @ProvinceCode IS NOT NULL
        SET @sql += N' AND c.ProvinceCode = @pProvinceCode';
    IF @ClientType IS NOT NULL
        SET @sql += N' AND c.ClientType = @pClientType';
    IF @IsActive IS NOT NULL
        SET @sql += N' AND c.IsActive = @pIsActive';
    IF @OnboardedFrom IS NOT NULL
        SET @sql += N' AND c.OnboardedDate >= @pOnboardedFrom';

    SET @sql += N' ORDER BY ' + @orderBy + N';';

    EXEC sys.sp_executesql
         @sql,
         N'@pNameContains NVARCHAR(100), @pProvinceCode CHAR(2), @pClientType CHAR(1),
           @pIsActive BIT, @pOnboardedFrom DATE, @pMaxRows INT',
         @pNameContains  = @NameContains,
         @pProvinceCode  = @ProvinceCode,
         @pClientType    = @ClientType,
         @pIsActive      = @IsActive,
         @pOnboardedFrom = @OnboardedFrom,
         @pMaxRows       = @MaxRows;
END
GO

/*==============================================================================
  acct.usp_PostJournalEntry

  Takes its lines as a table-valued parameter. Every validation runs before the
  transaction opens, so the THROWs cannot doom a transaction and the savepoint
  below stays usable when this is called from inside another procedure's
  transaction (which acct.usp_CloseFiscalYear does).
==============================================================================*/
CREATE OR ALTER PROCEDURE acct.usp_PostJournalEntry
(
    @ClientId       INT,
    @FiscalYearId   INT,
    @EntryDate      DATE,
    @Description    NVARCHAR(300),
    @Lines          acct.JournalLineType READONLY,
    @Source         NVARCHAR(20)  = N'Manual',
    @PostedBy       NVARCHAR(128) = NULL,
    @PostImmediately BIT          = 1,
    @JournalEntryId INT           OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    SET @PostedBy = ISNULL(@PostedBy, SUSER_SNAME());

    /*--- validation, all before any transaction is opened ---------------*/
    IF NOT EXISTS (SELECT 1 FROM @Lines)
        THROW 50006, 'A journal entry must have at least one line.', 1;

    DECLARE @debits  DECIMAL(19, 2),
            @credits DECIMAL(19, 2);

    SELECT @debits  = SUM(l.DebitAmount),
           @credits = SUM(l.CreditAmount)
    FROM   @Lines AS l;

    IF @debits <> @credits
    BEGIN
        DECLARE @msg NVARCHAR(200) =
            CONCAT(N'Journal entry does not balance: debits ', @debits,
                   N' vs credits ', @credits, N'.');
        THROW 50001, @msg, 1;
    END

    IF EXISTS (SELECT 1
               FROM   @Lines AS l
               WHERE  NOT EXISTS (SELECT 1
                                  FROM   acct.Account AS a
                                  WHERE  a.ClientId      = @ClientId
                                    AND  a.AccountNumber = l.AccountNumber))
        THROW 50002, 'One or more account numbers do not exist for this client.', 1;

    IF EXISTS (SELECT 1
               FROM   @Lines       AS l
               JOIN   acct.Account AS a ON a.ClientId = @ClientId
                                       AND a.AccountNumber = l.AccountNumber
               WHERE  a.IsControlAccount = 1)
        THROW 50003, 'Postings may not be made directly to a control account.', 1;

    IF EXISTS (SELECT 1 FROM acct.FiscalYear AS fy
               WHERE  fy.FiscalYearId = @FiscalYearId AND fy.IsClosed = 1)
        THROW 50004, 'The fiscal year is closed and will not accept new entries.', 1;

    IF NOT EXISTS (SELECT 1 FROM acct.FiscalYear AS fy
                   WHERE  fy.FiscalYearId = @FiscalYearId
                     AND  fy.ClientId     = @ClientId
                     AND  @EntryDate BETWEEN fy.StartDate AND fy.EndDate)
        THROW 50005, 'The entry date falls outside the given fiscal year.', 1;

    /*--- write ---------------------------------------------------------*/
    -- A savepoint when already inside a caller's transaction, a transaction of
    -- our own otherwise. Either way this procedure undoes only its own work.
    DECLARE @ownsTransaction BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    BEGIN TRY
        IF @ownsTransaction = 1
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION PostJournalEntry;

        DECLARE @entryNumber INT;
        SELECT @entryNumber = ISNULL(MAX(e.EntryNumber), 0) + 1
        FROM   acct.JournalEntry AS e WITH (UPDLOCK, HOLDLOCK)
        WHERE  e.ClientId = @ClientId;

        DECLARE @inserted TABLE (JournalEntryId INT NOT NULL);

        INSERT INTO acct.JournalEntry
            (ClientId, FiscalYearId, EntryNumber, EntryDate, Description,
             Source, IsPosted, PostedAt, PostedBy)
        OUTPUT inserted.JournalEntryId INTO @inserted (JournalEntryId)
        VALUES
            (@ClientId, @FiscalYearId, @entryNumber, @EntryDate, @Description,
             @Source,
             @PostImmediately,
             CASE WHEN @PostImmediately = 1 THEN SYSUTCDATETIME() END,
             CASE WHEN @PostImmediately = 1 THEN @PostedBy END);

        SELECT @JournalEntryId = JournalEntryId FROM @inserted;

        INSERT INTO acct.JournalLine
            (JournalEntryId, LineNumber, AccountId, DebitAmount, CreditAmount, Memo)
        SELECT @JournalEntryId,
               l.LineNumber,
               a.AccountId,
               l.DebitAmount,
               l.CreditAmount,
               l.Memo
        FROM   @Lines       AS l
        JOIN   acct.Account AS a ON a.ClientId      = @ClientId
                                AND a.AccountNumber = l.AccountNumber;

        IF @ownsTransaction = 1
            COMMIT TRANSACTION;

        SELECT @JournalEntryId AS JournalEntryId,
               @entryNumber    AS EntryNumber,
               @debits         AS TotalDebits,
               @credits        AS TotalCredits;
    END TRY
    BEGIN CATCH
        IF @ownsTransaction = 1 AND @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        ELSE IF @ownsTransaction = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION PostJournalEntry;
        THROW;
    END CATCH
END
GO

/*==============================================================================
  acct.usp_GenerateInvoice

  Allocates an invoice number from the sequence, then applies the sales tax
  rates in force in the client's province on the invoice date. GST/HST and PST
  are tracked separately because only the first is remitted to the CRA.
==============================================================================*/
CREATE OR ALTER PROCEDURE acct.usp_GenerateInvoice
(
    @ClientId     INT,
    @InvoiceDate  DATE,
    @Lines        acct.InvoiceLineType READONLY,
    @EngagementId INT           = NULL,
    @PaymentTerms INT           = 30,
    @Notes        NVARCHAR(400) = NULL,
    @Status       NVARCHAR(20)  = N'Sent',
    @InvoiceId    INT           OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM @Lines)
        THROW 50050, 'An invoice must have at least one line.', 1;

    DECLARE @provinceCode CHAR(2);
    SELECT @provinceCode = c.ProvinceCode
    FROM   client.Client AS c
    WHERE  c.ClientId = @ClientId;

    IF @provinceCode IS NULL
        THROW 50021, 'Unknown client.', 1;

    DECLARE @gstHstRate DECIMAL(9, 5) = ref.fn_GSTHSTRate(@provinceCode, @InvoiceDate),
            @pstRate    DECIMAL(9, 5) = ref.fn_PSTRate(@provinceCode, @InvoiceDate);

    DECLARE @subtotal      DECIMAL(19, 2),
            @taxableAmount DECIMAL(19, 2);

    SELECT @subtotal      = SUM(CONVERT(DECIMAL(19, 2), ROUND(l.Quantity * l.UnitPrice, 2))),
           @taxableAmount = SUM(CASE WHEN l.IsTaxable = 1
                                     THEN CONVERT(DECIMAL(19, 2), ROUND(l.Quantity * l.UnitPrice, 2))
                                     ELSE 0 END)
    FROM   @Lines AS l;

    DECLARE @gstHstAmount DECIMAL(19, 2) =
                CONVERT(DECIMAL(19, 2), ROUND(@taxableAmount * @gstHstRate, 2)),
            @pstAmount    DECIMAL(19, 2) =
                CONVERT(DECIMAL(19, 2), ROUND(@taxableAmount * @pstRate, 2));

    BEGIN TRY
        -- Writes begin here; see the note at the top of this file.
        SET XACT_ABORT ON;

        BEGIN TRANSACTION;

        DECLARE @invoiceNumber INT = NEXT VALUE FOR acct.seq_InvoiceNumber;
        DECLARE @created TABLE (InvoiceId INT NOT NULL, InvoiceNumber INT NOT NULL);

        INSERT INTO acct.Invoice
            (InvoiceNumber, ClientId, EngagementId, InvoiceDate, DueDate,
             ProvinceCode, Subtotal, GSTHSTAmount, PSTAmount, Status, Notes)
        OUTPUT inserted.InvoiceId, inserted.InvoiceNumber
               INTO @created (InvoiceId, InvoiceNumber)
        VALUES
            (@invoiceNumber, @ClientId, @EngagementId, @InvoiceDate,
             DATEADD(DAY, @PaymentTerms, @InvoiceDate),
             @provinceCode, @subtotal, @gstHstAmount, @pstAmount, @Status, @Notes);

        SELECT @InvoiceId = InvoiceId FROM @created;

        INSERT INTO acct.InvoiceLine
            (InvoiceId, LineNumber, Description, Quantity, UnitPrice, IsTaxable)
        SELECT @InvoiceId, l.LineNumber, l.Description, l.Quantity, l.UnitPrice, l.IsTaxable
        FROM   @Lines AS l;

        COMMIT TRANSACTION;

        SELECT c.InvoiceId,
               c.InvoiceNumber,
               @provinceCode  AS ProvinceCode,
               @gstHstRate    AS GSTHSTRate,
               @pstRate       AS PSTRate,
               @subtotal      AS Subtotal,
               @gstHstAmount  AS GSTHSTAmount,
               @pstAmount     AS PSTAmount,
               @subtotal + @gstHstAmount + @pstAmount AS Total
        FROM   @created AS c;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/*==============================================================================
  tax.usp_CalculateT1

  Recomputes a return from the rate tables and records the result as an
  immutable tax.Assessment row alongside the updated return.
==============================================================================*/
CREATE OR ALTER PROCEDURE tax.usp_CalculateT1
(
    @T1ReturnId     INT,
    @AssessmentType NVARCHAR(20) = N'Recalculation',
    @Notes          NVARCHAR(400) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @taxYear       SMALLINT,
            @province      CHAR(2),
            @taxableIncome DECIMAL(19, 2),
            @selfEmpIncome DECIMAL(19, 2),
            @isLocked      BIT;

    SELECT @taxYear       = r.TaxYear,
           @province      = r.ProvinceOfResidence,
           @taxableIncome = r.TaxableIncome,
           @selfEmpIncome = r.SelfEmploymentIncome,
           @isLocked      = y.IsLocked
    FROM   tax.T1Return AS r
    JOIN   ref.TaxYear  AS y ON y.TaxYear = r.TaxYear
    WHERE  r.T1ReturnId = @T1ReturnId;

    IF @taxYear IS NULL
        THROW 50010, 'T1 return not found.', 1;

    IF @isLocked = 1
        THROW 50011, 'The tax year is locked; returns for it may not be recalculated.', 1;

    /*--- calculation ---------------------------------------------------*/
    DECLARE @federalTax    DECIMAL(19, 2) = tax.fn_FederalTax(@taxYear, @taxableIncome),
            @provincialTax DECIMAL(19, 2) = tax.fn_ProvincialTax(@province, @taxYear, @taxableIncome);

    -- Non-refundable credits are claimed at the lowest bracket rate for the
    -- jurisdiction, which is why ref.NonRefundableCredit stores the rate.
    DECLARE @federalCredits    DECIMAL(19, 2),
            @provincialCredits DECIMAL(19, 2);

    SELECT @federalCredits = ISNULL(SUM(CONVERT(DECIMAL(19, 2),
                                 ROUND(cc.ClaimedAmount * nrc.CreditRate, 2))), 0)
    FROM   tax.CreditClaim           AS cc
    JOIN   ref.NonRefundableCredit   AS nrc
           ON  nrc.TaxYear          = cc.TaxYear
           AND nrc.JurisdictionCode = cc.JurisdictionCode
           AND nrc.CreditCode       = cc.CreditCode
    WHERE  cc.T1ReturnId       = @T1ReturnId
      AND  cc.JurisdictionCode = 'CA';

    SELECT @provincialCredits = ISNULL(SUM(CONVERT(DECIMAL(19, 2),
                                    ROUND(cc.ClaimedAmount * nrc.CreditRate, 2))), 0)
    FROM   tax.CreditClaim           AS cc
    JOIN   ref.NonRefundableCredit   AS nrc
           ON  nrc.TaxYear          = cc.TaxYear
           AND nrc.JurisdictionCode = cc.JurisdictionCode
           AND nrc.CreditCode       = cc.CreditCode
    WHERE  cc.T1ReturnId       = @T1ReturnId
      AND  cc.JurisdictionCode = @province;

    -- A self-employed taxpayer pays both halves of CPP.
    DECLARE @cppSelfEmployment DECIMAL(19, 2) =
        CASE WHEN @selfEmpIncome > 0
             THEN 2 * tax.fn_CPPContribution(@taxYear, @selfEmpIncome)
             ELSE 0
        END;

    DECLARE @netFederal    DECIMAL(19, 2) =
                CASE WHEN @federalTax - @federalCredits < 0 THEN 0
                     ELSE @federalTax - @federalCredits END,
            @netProvincial DECIMAL(19, 2) =
                CASE WHEN @provincialTax - @provincialCredits < 0 THEN 0
                     ELSE @provincialTax - @provincialCredits END;

    DECLARE @totalPayable DECIMAL(19, 2) = @netFederal + @netProvincial + @cppSelfEmployment;
    DECLARE @withheld     DECIMAL(19, 2),
            @installments DECIMAL(19, 2);

    SELECT @withheld     = r.TaxWithheld,
           @installments = r.InstallmentsPaid
    FROM   tax.T1Return AS r
    WHERE  r.T1ReturnId = @T1ReturnId;

    DECLARE @balanceOwing DECIMAL(19, 2) = @totalPayable - @withheld - @installments;

    /*--- write ---------------------------------------------------------*/
    BEGIN TRY
        -- Writes begin here; see the note at the top of this file.
        SET XACT_ABORT ON;

        BEGIN TRANSACTION;

        UPDATE tax.T1Return
        SET    FederalTax        = @federalTax,
               ProvincialTax     = @provincialTax,
               FederalCredits    = @federalCredits,
               ProvincialCredits = @provincialCredits,
               CPPSelfEmployment = @cppSelfEmployment,
               TotalPayable      = @totalPayable,
               BalanceOwing      = @balanceOwing,
               CalculatedAt      = SYSUTCDATETIME()
        WHERE  T1ReturnId = @T1ReturnId;

        INSERT INTO tax.Assessment
            (T1ReturnId, AssessmentType, TaxableIncome, FederalTax,
             ProvincialTax, TotalPayable, BalanceOwing, CalculationNotes)
        VALUES
            (@T1ReturnId, @AssessmentType, @taxableIncome, @federalTax,
             @provincialTax, @totalPayable, @balanceOwing,
             ISNULL(@Notes, CONCAT(N'Calculated from ', @taxYear, N' brackets for ', @province, N'.')));

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT @T1ReturnId        AS T1ReturnId,
           @taxYear           AS TaxYear,
           @province          AS ProvinceOfResidence,
           @taxableIncome     AS TaxableIncome,
           @federalTax        AS FederalTax,
           @provincialCredits AS ProvincialCredits,
           @federalCredits    AS FederalCredits,
           @provincialTax     AS ProvincialTax,
           @cppSelfEmployment AS CPPSelfEmployment,
           @totalPayable      AS TotalPayable,
           @balanceOwing      AS BalanceOwing,
           tax.fn_MarginalRate(@province, @taxYear, @taxableIncome) AS MarginalRate;
END
GO

/*==============================================================================
  tax.usp_RecalculateAllReturns

  Batch driver. Each return is recalculated inside its own TRY/CATCH so that a
  single bad return (a locked year, say) does not abandon the rest of the
  batch; the failures come back as a result set instead of an exception.
==============================================================================*/
CREATE OR ALTER PROCEDURE tax.usp_RecalculateAllReturns
(
    @TaxYear              SMALLINT = NULL,
    @ContinueOnError      BIT      = 1,
    -- Set to 0 to return only the summary. A caller using INSERT ... EXEC can
    -- capture one result set, not two, so the detail rows have to be optional.
    @IncludeFailureDetail BIT      = 1
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @results TABLE
    (
        T1ReturnId   INT           NOT NULL,
        Succeeded    BIT           NOT NULL,
        ErrorNumber  INT           NULL,
        ErrorMessage NVARCHAR(400) NULL
    );

    DECLARE @ids TABLE (T1ReturnId INT NOT NULL PRIMARY KEY);

    INSERT INTO @ids (T1ReturnId)
    SELECT r.T1ReturnId
    FROM   tax.T1Return AS r
    WHERE  (@TaxYear IS NULL OR r.TaxYear = @TaxYear);

    DECLARE @id INT;

    WHILE EXISTS (SELECT 1 FROM @ids)
    BEGIN
        SELECT TOP (1) @id = T1ReturnId FROM @ids ORDER BY T1ReturnId;

        BEGIN TRY
            EXEC tax.usp_CalculateT1
                 @T1ReturnId     = @id,
                 @AssessmentType = N'Recalculation';

            INSERT INTO @results (T1ReturnId, Succeeded) VALUES (@id, 1);
        END TRY
        BEGIN CATCH
            -- No ROLLBACK here, deliberately: this procedure is meant to be
            -- consumable via INSERT ... EXEC, and ROLLBACK is illegal inside
            -- one (error 3915). Recording the failure and continuing therefore
            -- depends on usp_CalculateT1 not leaving a doomed transaction
            -- behind - which is exactly what the XACT_ABORT discipline
            -- described at the top of this file guarantees.
            DECLARE @errNumber  INT           = ERROR_NUMBER(),
                    @errMessage NVARCHAR(400) = LEFT(ERROR_MESSAGE(), 400);

            INSERT INTO @results (T1ReturnId, Succeeded, ErrorNumber, ErrorMessage)
            VALUES (@id, 0, @errNumber, @errMessage);

            IF @ContinueOnError = 0
            BEGIN
                DELETE FROM @ids;      -- stop the loop
                BREAK;
            END
        END CATCH

        DELETE FROM @ids WHERE T1ReturnId = @id;
    END

    SELECT ISNULL(SUM(CASE WHEN Succeeded = 1 THEN 1 ELSE 0 END), 0) AS Succeeded,
           ISNULL(SUM(CASE WHEN Succeeded = 0 THEN 1 ELSE 0 END), 0) AS Failed,
           COUNT(*)                                                  AS Total
    FROM   @results;

    IF @IncludeFailureDetail = 1
        SELECT T1ReturnId, ErrorNumber, ErrorMessage
        FROM   @results
        WHERE  Succeeded = 0
        ORDER BY T1ReturnId;
END
GO

/*==============================================================================
  tax.usp_ImportSlips

  Slips arrive as JSON, each with a nested array of boxes. OPENJSON ... WITH
  projects both levels into relational shape, and MERGE makes re-importing the
  same payload a no-op rather than a duplicate.
==============================================================================*/
CREATE OR ALTER PROCEDURE tax.usp_ImportSlips
(
    @ClientId  INT,
    @TaxYear   SMALLINT,
    @SlipsJson NVARCHAR(MAX)
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @SlipsJson IS NULL OR ISJSON(@SlipsJson) <> 1
        THROW 50020, 'The slips payload is not valid JSON.', 1;

    IF NOT EXISTS (SELECT 1 FROM client.Client WHERE ClientId = @ClientId)
        THROW 50021, 'Unknown client.', 1;

    BEGIN TRY
        -- Writes begin here; see the note at the top of this file.
        SET XACT_ABORT ON;

        BEGIN TRANSACTION;

        DECLARE @incoming TABLE
        (
            SlipTypeCode         NVARCHAR(10)  NOT NULL,
            IssuerName           NVARCHAR(150) NOT NULL,
            IssuerBusinessNumber CHAR(9)       NULL,
            SlipReference        NVARCHAR(40)  NOT NULL,
            ReceivedDate         DATE          NULL,
            IsAmended            BIT           NOT NULL,
            Boxes                NVARCHAR(MAX) NULL
        );

        INSERT INTO @incoming
            (SlipTypeCode, IssuerName, IssuerBusinessNumber,
             SlipReference, ReceivedDate, IsAmended, Boxes)
        SELECT j.SlipTypeCode,
               j.IssuerName,
               j.IssuerBusinessNumber,
               j.SlipReference,
               j.ReceivedDate,
               ISNULL(j.IsAmended, 0),
               j.Boxes
        FROM   OPENJSON(@SlipsJson)
               WITH (
                   SlipTypeCode         NVARCHAR(10)  '$.slipType',
                   IssuerName           NVARCHAR(150) '$.issuer',
                   IssuerBusinessNumber CHAR(9)       '$.issuerBn',
                   SlipReference        NVARCHAR(40)  '$.reference',
                   ReceivedDate         DATE          '$.receivedDate',
                   IsAmended            BIT           '$.amended',
                   Boxes                NVARCHAR(MAX) '$.boxes' AS JSON
               ) AS j;

        DECLARE @slipIds TABLE
        (
            SlipId        INT          NOT NULL,
            SlipReference NVARCHAR(40) NOT NULL,
            SlipTypeCode  NVARCHAR(10) NOT NULL
        );

        MERGE tax.Slip WITH (HOLDLOCK) AS tgt
        USING (SELECT * FROM @incoming) AS src
              ON  tgt.ClientId      = @ClientId
              AND tgt.TaxYear       = @TaxYear
              AND tgt.SlipTypeCode  = src.SlipTypeCode
              AND tgt.SlipReference = src.SlipReference
        WHEN MATCHED THEN
            UPDATE SET IssuerName           = src.IssuerName,
                       IssuerBusinessNumber = src.IssuerBusinessNumber,
                       ReceivedDate         = src.ReceivedDate,
                       IsAmended            = src.IsAmended
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (ClientId, TaxYear, SlipTypeCode, IssuerName,
                    IssuerBusinessNumber, SlipReference, ReceivedDate, IsAmended)
            VALUES (@ClientId, @TaxYear, src.SlipTypeCode, src.IssuerName,
                    src.IssuerBusinessNumber, src.SlipReference,
                    src.ReceivedDate, src.IsAmended)
        OUTPUT inserted.SlipId, inserted.SlipReference, inserted.SlipTypeCode
               INTO @slipIds (SlipId, SlipReference, SlipTypeCode);

        -- Second level: the boxes nested inside each slip.
        DECLARE @boxes TABLE
        (
            SlipId       INT            NOT NULL,
            SlipTypeCode NVARCHAR(10)   NOT NULL,
            BoxNumber    NVARCHAR(10)   NOT NULL,
            Amount       DECIMAL(19, 2) NOT NULL,
            PRIMARY KEY (SlipId, BoxNumber)
        );

        INSERT INTO @boxes (SlipId, SlipTypeCode, BoxNumber, Amount)
        SELECT s.SlipId, s.SlipTypeCode, b.BoxNumber, b.Amount
        FROM   @incoming AS i
        JOIN   @slipIds  AS s ON s.SlipReference = i.SlipReference
                             AND s.SlipTypeCode  = i.SlipTypeCode
        CROSS  APPLY OPENJSON(i.Boxes)
               WITH (
                   BoxNumber NVARCHAR(10)   '$.box',
                   Amount    DECIMAL(19, 2) '$.amount'
               ) AS b;

        MERGE tax.SlipBox AS tgt
        USING (SELECT * FROM @boxes) AS src
              ON tgt.SlipId = src.SlipId AND tgt.BoxNumber = src.BoxNumber
        WHEN MATCHED THEN
            UPDATE SET Amount = src.Amount
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SlipId, SlipTypeCode, BoxNumber, Amount)
            VALUES (src.SlipId, src.SlipTypeCode, src.BoxNumber, src.Amount);

        COMMIT TRANSACTION;

        SELECT (SELECT COUNT(*) FROM @slipIds) AS SlipsProcessed,
               (SELECT COUNT(*) FROM @boxes)   AS BoxesProcessed;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/*==============================================================================
  tax.usp_FileGSTHSTReturn

  Derives the GST34 lines from the client's own books rather than accepting
  them as input:

    line 101  credits to revenue accounts over the period
    line 105  credits to the GST/HST payable account (tax collected)
    line 108  debits to the GST/HST recoverable account (input tax credits)

  Note this reads the *client's* ledger (acct.Account / acct.JournalEntry),
  not acct.Invoice - the latter is the practice billing its clients, which is
  the practice's own sales figure, not this client's.
==============================================================================*/
CREATE OR ALTER PROCEDURE tax.usp_FileGSTHSTReturn
(
    @ClientId                INT,
    @PeriodStart             DATE,
    @PeriodEnd               DATE,
    @FrequencyCode           NVARCHAR(10) = N'Quarterly',
    @GSTPayableAccountNumber NVARCHAR(20) = N'2310',
    @ITCAccountNumber        NVARCHAR(20) = N'1330',
    @GSTHSTReturnId          INT          OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM client.Client WHERE ClientId = @ClientId)
        THROW 50021, 'Unknown client.', 1;

    -- Two periods overlap when each starts before the other ends.
    IF EXISTS (SELECT 1
               FROM   tax.GSTHSTReturn AS g
               WHERE  g.ClientId     = @ClientId
                 AND  g.PeriodStart <= @PeriodEnd
                 AND  g.PeriodEnd   >= @PeriodStart)
        THROW 50030, 'A GST/HST return already exists overlapping this period.', 1;

    DECLARE @line101 DECIMAL(19, 2),
            @line105 DECIMAL(19, 2),
            @line108 DECIMAL(19, 2);

    -- Line 101: net credits to revenue accounts (a credit increases revenue).
    SELECT @line101 = ISNULL(SUM(l.CreditAmount - l.DebitAmount), 0)
    FROM   acct.JournalLine  AS l
    JOIN   acct.JournalEntry AS e ON e.JournalEntryId  = l.JournalEntryId
    JOIN   acct.Account      AS a ON a.AccountId       = l.AccountId
    JOIN   ref.AccountType   AS t ON t.AccountTypeCode = a.AccountTypeCode
    WHERE  a.ClientId       = @ClientId
      AND  t.AccountTypeCode = N'Revenue'
      AND  e.IsPosted       = 1
      AND  e.EntryDate BETWEEN @PeriodStart AND @PeriodEnd;

    -- Line 105: tax collected, accumulated as credits on the payable account.
    SELECT @line105 = ISNULL(SUM(l.CreditAmount - l.DebitAmount), 0)
    FROM   acct.JournalLine  AS l
    JOIN   acct.JournalEntry AS e ON e.JournalEntryId = l.JournalEntryId
    JOIN   acct.Account      AS a ON a.AccountId      = l.AccountId
    WHERE  a.ClientId      = @ClientId
      AND  a.AccountNumber = @GSTPayableAccountNumber
      AND  e.IsPosted      = 1
      AND  e.EntryDate BETWEEN @PeriodStart AND @PeriodEnd;

    IF @line101 < 0 SET @line101 = 0;
    IF @line105 < 0 SET @line105 = 0;

    -- Line 108: input tax credits, accumulated as debits on the recoverable
    -- account over the period.
    SELECT @line108 = ISNULL(SUM(l.DebitAmount - l.CreditAmount), 0)
    FROM   acct.JournalLine  AS l
    JOIN   acct.JournalEntry AS e ON e.JournalEntryId = l.JournalEntryId
    JOIN   acct.Account      AS a ON a.AccountId      = l.AccountId
    WHERE  a.ClientId      = @ClientId
      AND  a.AccountNumber = @ITCAccountNumber
      AND  e.IsPosted      = 1
      AND  e.EntryDate BETWEEN @PeriodStart AND @PeriodEnd;

    IF @line108 < 0 SET @line108 = 0;

    -- A GST/HST return is due one month after the period end for monthly and
    -- quarterly filers.
    DECLARE @dueDate DATE = DATEADD(MONTH, 1, @PeriodEnd);

    BEGIN TRY
        -- Writes begin here; see the note at the top of this file.
        SET XACT_ABORT ON;

        BEGIN TRANSACTION;

        DECLARE @created TABLE (GSTHSTReturnId INT NOT NULL);

        INSERT INTO tax.GSTHSTReturn
            (ClientId, PeriodStart, PeriodEnd, FrequencyCode,
             Line101Sales, Line105TaxCollected, Line108InputTaxCredits,
             FilingDueDate, FiledAt, Status)
        OUTPUT inserted.GSTHSTReturnId INTO @created (GSTHSTReturnId)
        VALUES
            (@ClientId, @PeriodStart, @PeriodEnd, @FrequencyCode,
             @line101, @line105, @line108,
             @dueDate, SYSUTCDATETIME(), N'Filed');

        SELECT @GSTHSTReturnId = GSTHSTReturnId FROM @created;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT g.GSTHSTReturnId,
           g.PeriodStart,
           g.PeriodEnd,
           g.Line101Sales,
           g.Line105TaxCollected,
           g.Line108InputTaxCredits,
           g.Line109NetTax,
           g.BalanceDue,
           g.FilingDueDate
    FROM   tax.GSTHSTReturn AS g
    WHERE  g.GSTHSTReturnId = @GSTHSTReturnId;
END
GO

/*==============================================================================
  tax.usp_GenerateClientYearEndPackage

  Returns five result sets in one round trip - the shape a reporting client
  binds to, and a useful target for a harness that has to assert across
  multiple results from a single call.
==============================================================================*/
CREATE OR ALTER PROCEDURE tax.usp_GenerateClientYearEndPackage
(
    @ClientId INT,
    @TaxYear  SMALLINT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM client.Client WHERE ClientId = @ClientId)
        THROW 50021, 'Unknown client.', 1;

    /*--- 1. who the client is ------------------------------------------*/
    SELECT d.ClientId, d.ClientCode, d.DisplayName, d.ClientType,
           d.ProvinceCode, d.ProvinceName, d.PrimaryEmail,
           d.Line1, d.City, d.PostalCode, d.IsActive
    FROM   client.vw_ClientDirectory AS d
    WHERE  d.ClientId = @ClientId;

    /*--- 2. income as reported on slips ---------------------------------*/
    SELECT st.EmploymentIncome, st.InvestmentIncome, st.SelfEmploymentIncome,
           st.PensionIncome, st.OtherIncome, st.Deductions, st.TaxWithheld,
           st.CPPContributions, st.EIPremiums, st.SlipCount
    FROM   tax.fn_ClientSlipTotals(@ClientId, @TaxYear) AS st;

    /*--- 3. the return, assessed vs recalculated ------------------------*/
    SELECT s.T1ReturnId, s.TaxYear, s.FilingStatus, s.TotalIncome, s.NetIncome,
           s.TaxableIncome, s.AssessedFederalTax, s.RecalculatedFederalTax,
           s.FederalTaxVariance, s.AssessedProvincialTax,
           s.RecalculatedProvincialTax, s.ProvincialTaxVariance,
           s.MarginalRate, s.AverageRate, s.TotalPayable, s.BalanceOwing
    FROM   tax.vw_T1ReturnSummary AS s
    WHERE  s.ClientId = @ClientId
      AND  s.TaxYear  = @TaxYear;

    /*--- 4. federal bracket breakdown -----------------------------------*/
    DECLARE @taxableIncome DECIMAL(19, 2);
    SELECT @taxableIncome = r.TaxableIncome
    FROM   tax.T1Return AS r
    WHERE  r.ClientId = @ClientId AND r.TaxYear = @TaxYear;

    SELECT bb.Ordinal, bb.LowerBound, bb.UpperBound, bb.Rate,
           bb.IncomeInBracket, bb.TaxInBracket, bb.CumulativeTax
    FROM   tax.fn_TaxBracketBreakdown('CA', @TaxYear, ISNULL(@taxableIncome, 0)) AS bb
    ORDER  BY bb.Ordinal;

    /*--- 5. what the client still owes the practice and the CRA ---------*/
    SELECT ag.InvoiceNumber, ag.InvoiceDate, ag.DueDate, ag.Total,
           ag.OutstandingAmount, ag.DaysOverdue, ag.AgingBucket
    FROM   acct.fn_InvoiceAging(CONVERT(DATE, SYSUTCDATETIME())) AS ag
    WHERE  ag.ClientId = @ClientId
    ORDER  BY ag.DueDate;
END
GO

/*==============================================================================
  acct.usp_CloseFiscalYear

  Closes every nominal (revenue and expense) account into retained earnings.

  Written with an explicit cursor. A set-based equivalent is possible and would
  be faster - the closing lines are just a SELECT over acct.fn_TrialBalance,
  which is how the retained-earnings balancing line below is in fact built. The
  cursor is kept because walking accounts one at a time is what the equivalent
  procedure looks like in most real ledgers, and it gives the schema a genuine
  cursor to exercise.
==============================================================================*/
CREATE OR ALTER PROCEDURE acct.usp_CloseFiscalYear
(
    @ClientId                     INT,
    @FiscalYearId                 INT,
    @RetainedEarningsAccountNumber NVARCHAR(20) = N'3200',
    @PostedBy                     NVARCHAR(128) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    SET @PostedBy = ISNULL(@PostedBy, SUSER_SNAME());

    DECLARE @endDate  DATE,
            @isClosed BIT;

    SELECT @endDate  = fy.EndDate,
           @isClosed = fy.IsClosed
    FROM   acct.FiscalYear AS fy
    WHERE  fy.FiscalYearId = @FiscalYearId AND fy.ClientId = @ClientId;

    IF @endDate IS NULL
        THROW 50005, 'Fiscal year not found for this client.', 1;

    IF @isClosed = 1
        THROW 50004, 'The fiscal year is already closed.', 1;

    IF NOT EXISTS (SELECT 1 FROM acct.Account
                   WHERE  ClientId = @ClientId
                     AND  AccountNumber = @RetainedEarningsAccountNumber)
        THROW 50002, 'The retained earnings account does not exist for this client.', 1;

    DECLARE @closingLines acct.JournalLineType;
    DECLARE @lineNumber   INT = 0,
            @netIncome    DECIMAL(19, 2) = 0;

    /*--- cursor over the nominal accounts carrying a balance -------------*/
    DECLARE @accountNumber NVARCHAR(20),
            @accountName   NVARCHAR(100),
            @normalBalance CHAR(1),
            @balance       DECIMAL(19, 2);

    DECLARE nominal_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT tb.AccountNumber, tb.AccountName, tb.NormalBalance, tb.Balance
        FROM   acct.fn_TrialBalance(@ClientId, @FiscalYearId, @endDate) AS tb
        JOIN   ref.AccountType AS t ON t.AccountTypeCode = tb.AccountTypeCode
        WHERE  tb.IsTotalRow = 0
          AND  t.IsNominal   = 1
          AND  tb.Balance   <> 0
        ORDER  BY tb.AccountNumber;

    OPEN nominal_cursor;
    FETCH NEXT FROM nominal_cursor
        INTO @accountNumber, @accountName, @normalBalance, @balance;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @lineNumber += 1;

        -- Closing an account means posting the opposite of its balance.
        IF @normalBalance = 'C'
        BEGIN
            -- Revenue: normally a credit balance, so debit it away.
            INSERT INTO @closingLines (LineNumber, AccountNumber, DebitAmount, CreditAmount, Memo)
            VALUES (@lineNumber, @accountNumber, @balance, 0,
                    CONCAT(N'Close ', @accountName));
            SET @netIncome += @balance;
        END
        ELSE
        BEGIN
            -- Expense: normally a debit balance, so credit it away.
            INSERT INTO @closingLines (LineNumber, AccountNumber, DebitAmount, CreditAmount, Memo)
            VALUES (@lineNumber, @accountNumber, 0, @balance,
                    CONCAT(N'Close ', @accountName));
            SET @netIncome -= @balance;
        END

        FETCH NEXT FROM nominal_cursor
            INTO @accountNumber, @accountName, @normalBalance, @balance;
    END

    CLOSE nominal_cursor;
    DEALLOCATE nominal_cursor;

    IF @lineNumber = 0
        THROW 50006, 'There are no nominal account balances to close.', 1;

    /*--- the balancing line to retained earnings ------------------------*/
    SET @lineNumber += 1;
    INSERT INTO @closingLines (LineNumber, AccountNumber, DebitAmount, CreditAmount, Memo)
    VALUES (@lineNumber,
            @RetainedEarningsAccountNumber,
            CASE WHEN @netIncome < 0 THEN -@netIncome ELSE 0 END,   -- a loss debits equity
            CASE WHEN @netIncome > 0 THEN  @netIncome ELSE 0 END,   -- a profit credits it
            N'Net income transferred to retained earnings');

    DECLARE @journalEntryId INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Nested call: usp_PostJournalEntry sees @@TRANCOUNT > 0 and takes a
        -- savepoint instead of opening its own transaction.
        EXEC acct.usp_PostJournalEntry
             @ClientId       = @ClientId,
             @FiscalYearId   = @FiscalYearId,
             @EntryDate      = @endDate,
             @Description    = N'Year-end closing entry',
             @Lines          = @closingLines,
             @Source         = N'YearEnd',
             @PostedBy       = @PostedBy,
             @JournalEntryId = @journalEntryId OUTPUT;

        UPDATE acct.FiscalYear
        SET    IsClosed = 1,
               ClosedAt = SYSUTCDATETIME()
        WHERE  FiscalYearId = @FiscalYearId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT @journalEntryId AS ClosingJournalEntryId,
           @lineNumber     AS LinesPosted,
           @netIncome      AS NetIncomeClosed;
END
GO

/*==============================================================================
  payroll.usp_RunPayroll

  Set-based: one INSERT..SELECT builds every paystub for the period, with
  CROSS APPLY calling the CPP and EI functions.

  CPP and EI both stop once an employee reaches the annual maximum, so each
  deduction is computed as (contribution on year-to-date + this period) minus
  (contribution on year-to-date). That difference automatically tapers to zero
  in the period the cap is reached, without any special-casing.
==============================================================================*/
CREATE OR ALTER PROCEDURE payroll.usp_RunPayroll
(
    @ClientId    INT,
    @PayPeriodId INT,
    @Force       BIT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @taxYear      SMALLINT,
            @periodNumber SMALLINT,
            @periodEnd    DATE,
            @payDate      DATE,
            @isProcessed  BIT;

    SELECT @taxYear      = pp.TaxYear,
           @periodNumber = pp.PeriodNumber,
           @periodEnd    = pp.EndDate,
           @payDate      = pp.PayDate,
           @isProcessed  = pp.IsProcessed
    FROM   payroll.PayPeriod AS pp
    WHERE  pp.PayPeriodId = @PayPeriodId AND pp.ClientId = @ClientId;

    IF @taxYear IS NULL
        THROW 50021, 'Pay period not found for this client.', 1;

    IF @isProcessed = 1 AND @Force = 0
        THROW 50060, 'This pay period has already been processed.', 1;

    BEGIN TRY
        -- Writes begin here; see the note at the top of this file.
        SET XACT_ABORT ON;

        BEGIN TRANSACTION;

        IF @Force = 1
            DELETE FROM payroll.Paystub WHERE PayPeriodId = @PayPeriodId;

        INSERT INTO payroll.Paystub
            (PayPeriodId, EmployeeId, GrossPay, CPPDeducted, CPP2Deducted,
             EIDeducted, FederalTaxDeducted, ProvincialTaxDeducted, OtherDeductions)
        SELECT @PayPeriodId,
               e.EmployeeId,
               calc.GrossPay,
               calc.CPPDeducted,
               calc.CPP2Deducted,
               calc.EIDeducted,
               calc.FederalTaxDeducted,
               calc.ProvincialTaxDeducted,
               0
        FROM   payroll.Employee AS e
        CROSS  APPLY
        (
            SELECT CASE e.PayFrequency
                        WHEN N'Weekly'      THEN 52
                        WHEN N'BiWeekly'    THEN 26
                        WHEN N'SemiMonthly' THEN 24
                        ELSE 12
                   END AS PeriodsPerYear
        ) AS freq
        CROSS  APPLY
        (
            SELECT CONVERT(DECIMAL(19, 2),
                       ROUND(e.AnnualSalary / freq.PeriodsPerYear, 2)) AS GrossPay
        ) AS pay
        CROSS  APPLY
        (
            -- Year-to-date gross for this employee before the current period.
            SELECT ISNULL(SUM(prior.GrossPay), 0) AS YtdGross
            FROM   payroll.Paystub   AS prior
            JOIN   payroll.PayPeriod AS pv ON pv.PayPeriodId = prior.PayPeriodId
            WHERE  prior.EmployeeId  = e.EmployeeId
              AND  pv.TaxYear        = @taxYear
              AND  pv.PeriodNumber   < @periodNumber
        ) AS ytd
        CROSS  APPLY
        (
            SELECT
                pay.GrossPay AS GrossPay,

                tax.fn_CPPContribution(@taxYear, ytd.YtdGross + pay.GrossPay)
                  - tax.fn_CPPContribution(@taxYear, ytd.YtdGross)      AS CPPDeducted,

                tax.fn_CPP2Contribution(@taxYear, ytd.YtdGross + pay.GrossPay)
                  - tax.fn_CPP2Contribution(@taxYear, ytd.YtdGross)     AS CPP2Deducted,

                tax.fn_EIPremium(@taxYear, ytd.YtdGross + pay.GrossPay, e.ProvinceOfEmployment)
                  - tax.fn_EIPremium(@taxYear, ytd.YtdGross, e.ProvinceOfEmployment)
                                                                        AS EIDeducted,

                -- Withholding estimate: annualize, tax the amount above the
                -- TD1 claim, then spread back over the periods in the year.
                CONVERT(DECIMAL(19, 2), ROUND(
                    tax.fn_FederalTax(@taxYear,
                        CASE WHEN e.AnnualSalary - e.TD1FederalAmount < 0 THEN 0
                             ELSE e.AnnualSalary - e.TD1FederalAmount END)
                    / freq.PeriodsPerYear, 2))                          AS FederalTaxDeducted,

                CONVERT(DECIMAL(19, 2), ROUND(
                    tax.fn_ProvincialTax(e.ProvinceOfEmployment, @taxYear,
                        CASE WHEN e.AnnualSalary - e.TD1ProvincialAmount < 0 THEN 0
                             ELSE e.AnnualSalary - e.TD1ProvincialAmount END)
                    / freq.PeriodsPerYear, 2))                          AS ProvincialTaxDeducted
        ) AS calc
        WHERE  e.EmployerClientId = @ClientId
          AND  e.IsActive         = 1
          AND  e.HireDate        <= @periodEnd
          AND  (e.TerminationDate IS NULL OR e.TerminationDate >= @periodEnd);

        UPDATE payroll.PayPeriod
        SET    IsProcessed = 1
        WHERE  PayPeriodId = @PayPeriodId;

        /*--- roll the period into the employer's remittance -------------*/
        DECLARE @cppEe DECIMAL(19, 2), @eiEe DECIMAL(19, 2), @taxWh DECIMAL(19, 2);
        DECLARE @eiMultiplier DECIMAL(9, 4);

        SELECT @cppEe = ISNULL(SUM(ps.CPPDeducted + ps.CPP2Deducted), 0),
               @eiEe  = ISNULL(SUM(ps.EIDeducted), 0),
               @taxWh = ISNULL(SUM(ps.FederalTaxDeducted + ps.ProvincialTaxDeducted), 0)
        FROM   payroll.Paystub AS ps
        WHERE  ps.PayPeriodId = @PayPeriodId;

        SELECT @eiMultiplier = p.EmployerEIMultiplier
        FROM   ref.PayrollRate AS p
        WHERE  p.TaxYear = @taxYear;

        SET @eiMultiplier = ISNULL(@eiMultiplier, 1.4);

        -- Remittances are due by the 15th of the month after the pay date.
        DECLARE @remitPeriodEnd DATE = EOMONTH(@payDate);
        DECLARE @remitDueDate   DATE = DATEFROMPARTS(YEAR(DATEADD(MONTH, 1, @remitPeriodEnd)),
                                                     MONTH(DATEADD(MONTH, 1, @remitPeriodEnd)), 15);

        MERGE payroll.Remittance WITH (HOLDLOCK) AS tgt
        USING (SELECT @ClientId AS ClientId, @remitPeriodEnd AS PeriodEnd) AS src
              ON tgt.ClientId = src.ClientId AND tgt.PeriodEnd = src.PeriodEnd
        WHEN MATCHED THEN
            UPDATE SET CPPEmployee       = tgt.CPPEmployee + @cppEe,
                       CPPEmployer       = tgt.CPPEmployer + @cppEe,
                       EIEmployee        = tgt.EIEmployee  + @eiEe,
                       EIEmployer        = tgt.EIEmployer
                                           + CONVERT(DECIMAL(19, 2), ROUND(@eiEe * @eiMultiplier, 2)),
                       IncomeTaxWithheld = tgt.IncomeTaxWithheld + @taxWh
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (ClientId, PeriodEnd, DueDate, CPPEmployee, CPPEmployer,
                    EIEmployee, EIEmployer, IncomeTaxWithheld)
            VALUES (@ClientId, @remitPeriodEnd, @remitDueDate, @cppEe, @cppEe,
                    @eiEe, CONVERT(DECIMAL(19, 2), ROUND(@eiEe * @eiMultiplier, 2)), @taxWh);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT COUNT(*)                     AS PaystubsCreated,
           SUM(ps.GrossPay)             AS TotalGross,
           SUM(ps.CPPDeducted + ps.CPP2Deducted) AS TotalCPP,
           SUM(ps.EIDeducted)           AS TotalEI,
           SUM(ps.FederalTaxDeducted + ps.ProvincialTaxDeducted) AS TotalIncomeTax,
           SUM(ps.NetPay)               AS TotalNet
    FROM   payroll.Paystub AS ps
    WHERE  ps.PayPeriodId = @PayPeriodId;
END
GO

/*==============================================================================
  audit.usp_PurgeChangeLog

  Deletes in bounded batches rather than one statement, so a large purge does
  not hold a single long transaction or escalate to a table lock.
==============================================================================*/
CREATE OR ALTER PROCEDURE audit.usp_PurgeChangeLog
(
    @RetentionDays INT = 365,
    @BatchSize     INT = 1000,
    @MaxBatches    INT = 1000,
    @RowsDeleted   INT = NULL OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RetentionDays < 0
        SET @RetentionDays = 0;
    IF @BatchSize < 1 OR @BatchSize > 100000
        SET @BatchSize = 1000;

    DECLARE @cutoff       DATETIME2(3) = DATEADD(DAY, -@RetentionDays, SYSUTCDATETIME());
    DECLARE @batchRows    INT = 1,
            @batchesRun   INT = 0;

    SET @RowsDeleted = 0;

    WHILE @batchRows > 0 AND @batchesRun < @MaxBatches
    BEGIN
        DELETE TOP (@BatchSize)
        FROM   audit.ChangeLog
        WHERE  ChangedAt < @cutoff;

        SET @batchRows   = @@ROWCOUNT;
        SET @RowsDeleted += @batchRows;
        SET @batchesRun  += 1;
    END

    SELECT @RowsDeleted AS RowsDeleted,
           @batchesRun  AS BatchesRun,
           @cutoff      AS CutoffUtc;
END
GO

PRINT '010 stored procedures ready.';
GO
