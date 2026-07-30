/*==============================================================================
  005 - Double-entry bookkeeping  [acct]

  Cascade design: client.Client cascades to FiscalYear, Account, JournalEntry
  and Invoice. Everything else is NO ACTION so there is never more than one
  cascade path into a table - acct.JournalLine, for instance, cascades from its
  JournalEntry but is deliberately restricted from acct.Account, so deleting a
  chart-of-accounts row that carries postings fails loudly.
==============================================================================*/
USE CdnTaxPractice;
GO

/*--------------------------------------------------------------------------
  Fiscal years per client.
--------------------------------------------------------------------------*/
IF OBJECT_ID('acct.FiscalYear', 'U') IS NULL
CREATE TABLE acct.FiscalYear
(
    FiscalYearId INT          NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_FiscalYear PRIMARY KEY CLUSTERED,
    ClientId     INT          NOT NULL,
    StartDate    DATE         NOT NULL,
    EndDate      DATE         NOT NULL,
    IsClosed     BIT          NOT NULL CONSTRAINT DF_FiscalYear_IsClosed DEFAULT (0),
    ClosedAt     DATETIME2(3) NULL,
    CONSTRAINT UQ_FiscalYear UNIQUE (ClientId, EndDate),
    CONSTRAINT FK_FiscalYear_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT CK_FiscalYear_Period CHECK (EndDate > StartDate),
    CONSTRAINT CK_FiscalYear_Closed
        CHECK ((IsClosed = 0 AND ClosedAt IS NULL) OR (IsClosed = 1 AND ClosedAt IS NOT NULL))
);
GO

/*--------------------------------------------------------------------------
  Chart of accounts. ParentAccountId is self-referencing, which is what
  acct.fn_AccountHierarchy walks with a recursive CTE.
--------------------------------------------------------------------------*/
IF OBJECT_ID('acct.Account', 'U') IS NULL
CREATE TABLE acct.Account
(
    AccountId       INT           NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_Account PRIMARY KEY CLUSTERED,
    ClientId        INT           NOT NULL,
    AccountNumber   NVARCHAR(20)  NOT NULL,
    AccountName     NVARCHAR(100) NOT NULL,
    AccountTypeCode NVARCHAR(20)  NOT NULL,
    ParentAccountId INT           NULL,
    IsActive        BIT           NOT NULL CONSTRAINT DF_Account_IsActive DEFAULT (1),
    -- A control account is a roll-up header and must not be posted to directly.
    IsControlAccount BIT          NOT NULL CONSTRAINT DF_Account_IsControl DEFAULT (0),
    CONSTRAINT UQ_Account UNIQUE (ClientId, AccountNumber),
    CONSTRAINT FK_Account_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT FK_Account_AccountType
        FOREIGN KEY (AccountTypeCode) REFERENCES ref.AccountType (AccountTypeCode),
    -- Self-reference must be NO ACTION; a cascading self-FK is not permitted.
    CONSTRAINT FK_Account_Parent
        FOREIGN KEY (ParentAccountId) REFERENCES acct.Account (AccountId),
    CONSTRAINT CK_Account_NotOwnParent CHECK (ParentAccountId IS NULL OR ParentAccountId <> AccountId)
);
GO

/*--------------------------------------------------------------------------
  Journal entries. Posting is one-way: acct.tr_JournalLine_NoPostedEdits
  rejects any change to the lines of a posted entry, so corrections must be
  made by a reversing entry (ReversedByEntryId).
--------------------------------------------------------------------------*/
IF OBJECT_ID('acct.JournalEntry', 'U') IS NULL
CREATE TABLE acct.JournalEntry
(
    JournalEntryId    INT           NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_JournalEntry PRIMARY KEY CLUSTERED,
    ClientId          INT           NOT NULL,
    FiscalYearId      INT           NOT NULL,
    EntryNumber       INT           NOT NULL,
    EntryDate         DATE          NOT NULL,
    Description       NVARCHAR(300) NOT NULL,
    Source            NVARCHAR(20)  NOT NULL CONSTRAINT DF_JournalEntry_Source DEFAULT (N'Manual'),
    IsPosted          BIT           NOT NULL CONSTRAINT DF_JournalEntry_IsPosted DEFAULT (0),
    PostedAt          DATETIME2(3)  NULL,
    PostedBy          NVARCHAR(128) NULL,
    ReversedByEntryId INT           NULL,
    CreatedAt         DATETIME2(3)  NOT NULL CONSTRAINT DF_JournalEntry_Created DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT UQ_JournalEntry UNIQUE (ClientId, EntryNumber),
    CONSTRAINT FK_JournalEntry_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    -- NO ACTION: a second cascade path into this table is not allowed.
    CONSTRAINT FK_JournalEntry_FiscalYear
        FOREIGN KEY (FiscalYearId) REFERENCES acct.FiscalYear (FiscalYearId),
    CONSTRAINT FK_JournalEntry_Reversal
        FOREIGN KEY (ReversedByEntryId) REFERENCES acct.JournalEntry (JournalEntryId),
    CONSTRAINT CK_JournalEntry_Source
        CHECK (Source IN (N'Manual', N'Invoice', N'Payment', N'Payroll', N'YearEnd', N'Adjustment')),
    CONSTRAINT CK_JournalEntry_Posted
        CHECK ((IsPosted = 0 AND PostedAt IS NULL AND PostedBy IS NULL)
            OR (IsPosted = 1 AND PostedAt IS NOT NULL AND PostedBy IS NOT NULL)),
    CONSTRAINT CK_JournalEntry_NoSelfReversal
        CHECK (ReversedByEntryId IS NULL OR ReversedByEntryId <> JournalEntryId)
);
GO

/*--------------------------------------------------------------------------
  Journal lines. Exactly one side of each line carries an amount; balance
  across the entry is enforced procedurally by acct.usp_PostJournalEntry
  (a per-row CHECK cannot see the other rows of the entry).
--------------------------------------------------------------------------*/
IF OBJECT_ID('acct.JournalLine', 'U') IS NULL
CREATE TABLE acct.JournalLine
(
    JournalLineId  INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_JournalLine PRIMARY KEY CLUSTERED,
    JournalEntryId INT            NOT NULL,
    LineNumber     INT            NOT NULL,
    AccountId      INT            NOT NULL,
    DebitAmount    DECIMAL(19, 2) NOT NULL CONSTRAINT DF_JournalLine_Debit  DEFAULT (0),
    CreditAmount   DECIMAL(19, 2) NOT NULL CONSTRAINT DF_JournalLine_Credit DEFAULT (0),
    Memo           NVARCHAR(200)  NULL,
    CONSTRAINT UQ_JournalLine UNIQUE (JournalEntryId, LineNumber),
    CONSTRAINT FK_JournalLine_JournalEntry
        FOREIGN KEY (JournalEntryId) REFERENCES acct.JournalEntry (JournalEntryId) ON DELETE CASCADE,
    -- NO ACTION on purpose: an account with postings must not be deletable.
    CONSTRAINT FK_JournalLine_Account
        FOREIGN KEY (AccountId) REFERENCES acct.Account (AccountId),
    CONSTRAINT CK_JournalLine_NonNegative CHECK (DebitAmount >= 0 AND CreditAmount >= 0),
    CONSTRAINT CK_JournalLine_OneSided
        CHECK ((DebitAmount > 0 AND CreditAmount = 0) OR (CreditAmount > 0 AND DebitAmount = 0))
);
GO

/*--------------------------------------------------------------------------
  Invoices raised by the practice. InvoiceNumber comes from
  acct.seq_InvoiceNumber, allocated by acct.usp_GenerateInvoice.

  Subtotal and the tax amounts are stored rather than computed from the lines
  because they are what was actually billed; acct.usp_GenerateInvoice derives
  them, and 099_verify.sql asserts they agree with the lines.
--------------------------------------------------------------------------*/
IF OBJECT_ID('acct.Invoice', 'U') IS NULL
CREATE TABLE acct.Invoice
(
    InvoiceId     INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_Invoice PRIMARY KEY CLUSTERED,
    InvoiceNumber INT            NOT NULL,
    ClientId      INT            NOT NULL,
    EngagementId  INT            NULL,
    InvoiceDate   DATE           NOT NULL,
    DueDate       DATE           NOT NULL,
    -- The province whose rate applied - the client's province of supply at the
    -- time of billing, captured so a later address change cannot rewrite history.
    ProvinceCode  CHAR(2)        NOT NULL,
    Subtotal      DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Invoice_Subtotal DEFAULT (0),
    GSTHSTAmount  DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Invoice_GstHst   DEFAULT (0),
    PSTAmount     DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Invoice_Pst      DEFAULT (0),
    Total AS (Subtotal + GSTHSTAmount + PSTAmount) PERSISTED NOT NULL,
    Status        NVARCHAR(20)   NOT NULL CONSTRAINT DF_Invoice_Status DEFAULT (N'Draft'),
    Notes         NVARCHAR(400)  NULL,
    CreatedAt     DATETIME2(3)   NOT NULL CONSTRAINT DF_Invoice_Created DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT UQ_Invoice_Number UNIQUE (InvoiceNumber),
    CONSTRAINT FK_Invoice_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT FK_Invoice_Engagement
        FOREIGN KEY (EngagementId) REFERENCES client.Engagement (EngagementId),
    CONSTRAINT FK_Invoice_Province
        FOREIGN KEY (ProvinceCode) REFERENCES ref.Province (ProvinceCode),
    CONSTRAINT CK_Invoice_Dates   CHECK (DueDate >= InvoiceDate),
    CONSTRAINT CK_Invoice_Amounts CHECK (Subtotal >= 0 AND GSTHSTAmount >= 0 AND PSTAmount >= 0),
    CONSTRAINT CK_Invoice_Status
        CHECK (Status IN (N'Draft', N'Sent', N'PartiallyPaid', N'Paid', N'Void', N'WrittenOff'))
);
GO

IF OBJECT_ID('acct.InvoiceLine', 'U') IS NULL
CREATE TABLE acct.InvoiceLine
(
    InvoiceLineId INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_InvoiceLine PRIMARY KEY CLUSTERED,
    InvoiceId     INT            NOT NULL,
    LineNumber    INT            NOT NULL,
    Description   NVARCHAR(200)  NOT NULL,
    Quantity      DECIMAL(9, 2)  NOT NULL CONSTRAINT DF_InvoiceLine_Qty DEFAULT (1),
    UnitPrice     DECIMAL(19, 2) NOT NULL,
    IsTaxable     BIT            NOT NULL CONSTRAINT DF_InvoiceLine_Taxable DEFAULT (1),
    -- CONVERT pins the result type; without it the product widens the scale.
    LineTotal AS (CONVERT(DECIMAL(19, 2), ROUND(Quantity * UnitPrice, 2))) PERSISTED NOT NULL,
    CONSTRAINT UQ_InvoiceLine UNIQUE (InvoiceId, LineNumber),
    CONSTRAINT FK_InvoiceLine_Invoice
        FOREIGN KEY (InvoiceId) REFERENCES acct.Invoice (InvoiceId) ON DELETE CASCADE,
    CONSTRAINT CK_InvoiceLine_Amounts CHECK (Quantity > 0 AND UnitPrice >= 0)
);
GO

IF OBJECT_ID('acct.Payment', 'U') IS NULL
CREATE TABLE acct.Payment
(
    PaymentId   INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_Payment PRIMARY KEY CLUSTERED,
    InvoiceId   INT            NOT NULL,
    PaymentDate DATE           NOT NULL,
    Amount      DECIMAL(19, 2) NOT NULL,
    Method      NVARCHAR(20)   NOT NULL,
    Reference   NVARCHAR(60)   NULL,
    CONSTRAINT FK_Payment_Invoice
        FOREIGN KEY (InvoiceId) REFERENCES acct.Invoice (InvoiceId) ON DELETE CASCADE,
    CONSTRAINT CK_Payment_Amount CHECK (Amount > 0),
    CONSTRAINT CK_Payment_Method
        CHECK (Method IN (N'Cheque', N'EFT', N'CreditCard', N'Cash', N'Interac'))
);
GO

PRINT '005 accounting tables ready.';
GO
