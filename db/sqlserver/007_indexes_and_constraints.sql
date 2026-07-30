/*==============================================================================
  007 - Secondary indexes and a synonym

  Deliberately covers several index shapes:
    - unique filtered  : uniqueness that only applies to non-NULL rows
    - filtered         : "one primary per parent", and hot-subset indexes
    - covering         : key + INCLUDE, sized to the query that reads it
    - computed-column  : index over a persisted computed column

  Filtered-index predicates are kept to forms SQL Server accepts everywhere
  (equality, IS NULL) - OR and <> are not supported in a filtered predicate.
==============================================================================*/
USE CdnTaxPractice;
GO

/*--------------------------------------------------------------------------
  Helper: every index below is guarded so this file can be re-run.
--------------------------------------------------------------------------*/

/*----------------------------- client -----------------------------------*/

-- A SIN identifies exactly one individual, but corporations have none: unique
-- only across the rows where it is present.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UX_Client_SIN' AND object_id = OBJECT_ID('client.Client'))
    CREATE UNIQUE NONCLUSTERED INDEX UX_Client_SIN
        ON client.Client (SIN) WHERE SIN IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UX_Client_BusinessNumber' AND object_id = OBJECT_ID('client.Client'))
    CREATE UNIQUE NONCLUSTERED INDEX UX_Client_BusinessNumber
        ON client.Client (BusinessNumber) WHERE BusinessNumber IS NOT NULL;
GO

-- Hot subset: nearly every screen filters to active clients.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Client_Active' AND object_id = OBJECT_ID('client.Client'))
    CREATE NONCLUSTERED INDEX IX_Client_Active
        ON client.Client (ProvinceCode, ClientType)
        INCLUDE (ClientCode, DisplayName)
        WHERE IsActive = 1;
GO

-- Index over a persisted computed column, for name search / ordering.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Client_DisplayName' AND object_id = OBJECT_ID('client.Client'))
    CREATE NONCLUSTERED INDEX IX_Client_DisplayName
        ON client.Client (DisplayName) INCLUDE (ClientId, IsActive);
GO

-- At most one primary address per client.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UX_ClientAddress_Primary' AND object_id = OBJECT_ID('client.ClientAddress'))
    CREATE UNIQUE NONCLUSTERED INDEX UX_ClientAddress_Primary
        ON client.ClientAddress (ClientId) WHERE IsPrimary = 1;
GO

-- At most one primary contact per client per contact type.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UX_ClientContact_Primary' AND object_id = OBJECT_ID('client.ClientContact'))
    CREATE UNIQUE NONCLUSTERED INDEX UX_ClientContact_Primary
        ON client.ClientContact (ClientId, ContactType) WHERE IsPrimary = 1;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Engagement_Practitioner' AND object_id = OBJECT_ID('client.Engagement'))
    CREATE NONCLUSTERED INDEX IX_Engagement_Practitioner
        ON client.Engagement (PractitionerId, Status) INCLUDE (ClientId, TaxYear, FeeQuoted);
GO

/*------------------------------- ref ------------------------------------*/

-- Covering: tax.fn_FederalTax reads exactly these columns for a year.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_TaxBracket_Lookup' AND object_id = OBJECT_ID('ref.TaxBracket'))
    CREATE NONCLUSTERED INDEX IX_TaxBracket_Lookup
        ON ref.TaxBracket (TaxYear, JurisdictionCode, Ordinal)
        INCLUDE (LowerBound, UpperBound, Rate);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_SalesTaxRate_Lookup' AND object_id = OBJECT_ID('ref.SalesTaxRate'))
    CREATE NONCLUSTERED INDEX IX_SalesTaxRate_Lookup
        ON ref.SalesTaxRate (ProvinceCode, EffectiveFrom)
        INCLUDE (EffectiveTo, GSTRate, HSTRate, PSTRate, QSTRate, CombinedRate);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_StatutoryHoliday_Date' AND object_id = OBJECT_ID('ref.StatutoryHoliday'))
    CREATE NONCLUSTERED INDEX IX_StatutoryHoliday_Date
        ON ref.StatutoryHoliday (HolidayDate) INCLUDE (JurisdictionCode);
GO

/*------------------------------- tax ------------------------------------*/

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Slip_ClientYear' AND object_id = OBJECT_ID('tax.Slip'))
    CREATE NONCLUSTERED INDEX IX_Slip_ClientYear
        ON tax.Slip (ClientId, TaxYear) INCLUDE (SlipTypeCode, IssuerName, IsAmended);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_SlipBox_TypeBox' AND object_id = OBJECT_ID('tax.SlipBox'))
    CREATE NONCLUSTERED INDEX IX_SlipBox_TypeBox
        ON tax.SlipBox (SlipTypeCode, BoxNumber) INCLUDE (SlipId, Amount);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_T1Return_YearStatus' AND object_id = OBJECT_ID('tax.T1Return'))
    CREATE NONCLUSTERED INDEX IX_T1Return_YearStatus
        ON tax.T1Return (TaxYear, FilingStatus)
        INCLUDE (ClientId, TaxableIncome, TotalPayable, BalanceOwing);
GO

-- Work queue: returns not yet filed.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_T1Return_Unfiled' AND object_id = OBJECT_ID('tax.T1Return'))
    CREATE NONCLUSTERED INDEX IX_T1Return_Unfiled
        ON tax.T1Return (TaxYear, ClientId) INCLUDE (FilingStatus)
        WHERE DateFiled IS NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_GSTHSTReturn_Unfiled' AND object_id = OBJECT_ID('tax.GSTHSTReturn'))
    CREATE NONCLUSTERED INDEX IX_GSTHSTReturn_Unfiled
        ON tax.GSTHSTReturn (FilingDueDate, ClientId) INCLUDE (PeriodStart, PeriodEnd)
        WHERE FiledAt IS NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Assessment_Return' AND object_id = OBJECT_ID('tax.Assessment'))
    CREATE NONCLUSTERED INDEX IX_Assessment_Return
        ON tax.Assessment (T1ReturnId, AssessedOn DESC)
        INCLUDE (AssessmentType, TotalPayable, BalanceOwing);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Installment_ClientYear' AND object_id = OBJECT_ID('tax.Installment'))
    CREATE NONCLUSTERED INDEX IX_Installment_ClientYear
        ON tax.Installment (ClientId, TaxYear) INCLUDE (AmountDue, AmountPaid, DueDate);
GO

/*------------------------------ acct ------------------------------------*/

-- Covering index for acct.fn_AccountBalance / fn_TrialBalance.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_JournalLine_Account' AND object_id = OBJECT_ID('acct.JournalLine'))
    CREATE NONCLUSTERED INDEX IX_JournalLine_Account
        ON acct.JournalLine (AccountId)
        INCLUDE (JournalEntryId, DebitAmount, CreditAmount);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_JournalEntry_ClientDate' AND object_id = OBJECT_ID('acct.JournalEntry'))
    CREATE NONCLUSTERED INDEX IX_JournalEntry_ClientDate
        ON acct.JournalEntry (ClientId, EntryDate)
        INCLUDE (FiscalYearId, IsPosted, Source, EntryNumber);
GO

-- Unposted entries are the ones an operator is working on.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_JournalEntry_Unposted' AND object_id = OBJECT_ID('acct.JournalEntry'))
    CREATE NONCLUSTERED INDEX IX_JournalEntry_Unposted
        ON acct.JournalEntry (ClientId, EntryDate) INCLUDE (Description)
        WHERE IsPosted = 0;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Account_Parent' AND object_id = OBJECT_ID('acct.Account'))
    CREATE NONCLUSTERED INDEX IX_Account_Parent
        ON acct.Account (ParentAccountId) INCLUDE (ClientId, AccountNumber, AccountName);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Account_ClientType' AND object_id = OBJECT_ID('acct.Account'))
    CREATE NONCLUSTERED INDEX IX_Account_ClientType
        ON acct.Account (ClientId, AccountTypeCode)
        INCLUDE (AccountNumber, AccountName, IsControlAccount);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Invoice_ClientDate' AND object_id = OBJECT_ID('acct.Invoice'))
    CREATE NONCLUSTERED INDEX IX_Invoice_ClientDate
        ON acct.Invoice (ClientId, InvoiceDate)
        INCLUDE (DueDate, Subtotal, GSTHSTAmount, PSTAmount, Total, Status);
GO

-- Receivables: invoices sent but not yet settled.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Invoice_Outstanding' AND object_id = OBJECT_ID('acct.Invoice'))
    CREATE NONCLUSTERED INDEX IX_Invoice_Outstanding
        ON acct.Invoice (DueDate, ClientId) INCLUDE (InvoiceNumber, Total)
        WHERE Status = N'Sent';
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Payment_Invoice' AND object_id = OBJECT_ID('acct.Payment'))
    CREATE NONCLUSTERED INDEX IX_Payment_Invoice
        ON acct.Payment (InvoiceId, PaymentDate) INCLUDE (Amount, Method);
GO

/*----------------------------- payroll ----------------------------------*/

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Paystub_Employee' AND object_id = OBJECT_ID('payroll.Paystub'))
    CREATE NONCLUSTERED INDEX IX_Paystub_Employee
        ON payroll.Paystub (EmployeeId)
        INCLUDE (PayPeriodId, GrossPay, CPPDeducted, CPP2Deducted, EIDeducted,
                 FederalTaxDeducted, ProvincialTaxDeducted, NetPay);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_PayPeriod_ClientYear' AND object_id = OBJECT_ID('payroll.PayPeriod'))
    CREATE NONCLUSTERED INDEX IX_PayPeriod_ClientYear
        ON payroll.PayPeriod (ClientId, TaxYear, PayDate) INCLUDE (PeriodNumber, IsProcessed);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_Employee_Employer' AND object_id = OBJECT_ID('payroll.Employee'))
    CREATE NONCLUSTERED INDEX IX_Employee_Employer
        ON payroll.Employee (EmployerClientId) INCLUDE (LastName, FirstName, AnnualSalary)
        WHERE IsActive = 1;
GO

/*------------------------------ audit -----------------------------------*/

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_ChangeLog_ChangedAt' AND object_id = OBJECT_ID('audit.ChangeLog'))
    CREATE NONCLUSTERED INDEX IX_ChangeLog_ChangedAt
        ON audit.ChangeLog (ChangedAt DESC) INCLUDE (SchemaName, TableName, Operation, ChangedBy);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_ChangeLog_Row' AND object_id = OBJECT_ID('audit.ChangeLog'))
    CREATE NONCLUSTERED INDEX IX_ChangeLog_Row
        ON audit.ChangeLog (TableName, PrimaryKeyValue, ChangedAt DESC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_ReturnStatusHistory_Return'
                 AND object_id = OBJECT_ID('audit.ReturnStatusHistory'))
    CREATE NONCLUSTERED INDEX IX_ReturnStatusHistory_Return
        ON audit.ReturnStatusHistory (T1ReturnId, ChangedAt DESC);
GO

/*--------------------------------------------------------------------------
  A synonym, so legacy callers that expect a dbo-qualified name keep working
  after the move into the client schema.
--------------------------------------------------------------------------*/
IF OBJECT_ID('dbo.Clients', 'SN') IS NULL
    CREATE SYNONYM dbo.Clients FOR client.Client;
GO

PRINT '007 indexes and synonym ready.';
GO
