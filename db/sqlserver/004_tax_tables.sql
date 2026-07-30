/*==============================================================================
  004 - Tax filings  [tax]

  Note on computed columns: every computed column here is expressed purely over
  *stored* columns, never over another computed column. SQL Server permits the
  chained form, but PostgreSQL generated columns do not, and keeping one level
  makes the eventual port mechanical.

  Figures that represent an assessed *fact* (TotalPayable, BalanceOwing) are
  stored, not computed - they are written by tax.usp_CalculateT1 and compared
  against a live recalculation in tax.vw_T1ReturnSummary.
==============================================================================*/
USE CdnTaxPractice;
GO

/*--------------------------------------------------------------------------
  T1 - personal income tax return.
--------------------------------------------------------------------------*/
IF OBJECT_ID('tax.T1Return', 'U') IS NULL
CREATE TABLE tax.T1Return
(
    T1ReturnId              INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_T1Return PRIMARY KEY CLUSTERED,
    ClientId                INT            NOT NULL,
    TaxYear                 SMALLINT       NOT NULL,
    ProvinceOfResidence     CHAR(2)        NOT NULL,
    FilingStatus            NVARCHAR(20)   NOT NULL CONSTRAINT DF_T1Return_Status DEFAULT (N'Draft'),
    MaritalStatus           NVARCHAR(20)   NULL,
    IsSelfEmployed          BIT            NOT NULL CONSTRAINT DF_T1Return_SelfEmp DEFAULT (0),

    -- Income (total income lines)
    EmploymentIncome        DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_Employment DEFAULT (0),
    InvestmentIncome        DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_Investment DEFAULT (0),
    SelfEmploymentIncome    DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_SelfEmp    DEFAULT (0),
    PensionIncome           DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_Pension    DEFAULT (0),
    OtherIncome             DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_Other      DEFAULT (0),

    -- Deductions
    RRSPDeduction           DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_RRSP       DEFAULT (0),
    UnionDues               DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_Union      DEFAULT (0),
    ChildCareExpenses       DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_ChildCare  DEFAULT (0),
    OtherDeductions         DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_OtherDed   DEFAULT (0),
    LossCarryforward        DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_Loss       DEFAULT (0),

    -- Derived income figures
    TotalIncome AS (EmploymentIncome + InvestmentIncome + SelfEmploymentIncome
                    + PensionIncome + OtherIncome) PERSISTED NOT NULL,
    TotalDeductions AS (RRSPDeduction + UnionDues + ChildCareExpenses
                        + OtherDeductions) PERSISTED NOT NULL,
    NetIncome AS (EmploymentIncome + InvestmentIncome + SelfEmploymentIncome
                  + PensionIncome + OtherIncome
                  - RRSPDeduction - UnionDues - ChildCareExpenses
                  - OtherDeductions) PERSISTED NOT NULL,
    -- Taxable income cannot go below zero once losses are applied.
    TaxableIncome AS (CASE WHEN EmploymentIncome + InvestmentIncome + SelfEmploymentIncome
                                + PensionIncome + OtherIncome
                                - RRSPDeduction - UnionDues - ChildCareExpenses
                                - OtherDeductions - LossCarryforward < 0
                           THEN CONVERT(DECIMAL(19, 2), 0)
                           ELSE EmploymentIncome + InvestmentIncome + SelfEmploymentIncome
                                + PensionIncome + OtherIncome
                                - RRSPDeduction - UnionDues - ChildCareExpenses
                                - OtherDeductions - LossCarryforward
                      END) PERSISTED NOT NULL,

    -- Tax, written by tax.usp_CalculateT1
    FederalTax              DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_FedTax    DEFAULT (0),
    ProvincialTax           DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_ProvTax   DEFAULT (0),
    FederalCredits          DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_FedCred   DEFAULT (0),
    ProvincialCredits       DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_ProvCred  DEFAULT (0),
    CPPSelfEmployment       DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_CPPSE     DEFAULT (0),
    EISelfEmployment        DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_EISE      DEFAULT (0),

    -- Credits cannot create a refund, hence the floor at zero.
    NetFederalTax AS (CASE WHEN FederalTax - FederalCredits < 0
                           THEN CONVERT(DECIMAL(19, 2), 0)
                           ELSE FederalTax - FederalCredits END) PERSISTED NOT NULL,
    NetProvincialTax AS (CASE WHEN ProvincialTax - ProvincialCredits < 0
                              THEN CONVERT(DECIMAL(19, 2), 0)
                              ELSE ProvincialTax - ProvincialCredits END) PERSISTED NOT NULL,

    -- Payments
    TaxWithheld             DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_Withheld    DEFAULT (0),
    InstallmentsPaid        DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_Installments DEFAULT (0),

    -- Assessed facts, written by the calculation procedure
    TotalPayable            DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_Payable  DEFAULT (0),
    BalanceOwing            DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T1_Balance  DEFAULT (0),

    DateFiled               DATE           NULL,
    CalculatedAt            DATETIME2(3)   NULL,
    AssessedAt              DATETIME2(3)   NULL,
    NoticeOfAssessmentNo    NVARCHAR(25)   NULL,
    CreatedAt               DATETIME2(3)   NOT NULL CONSTRAINT DF_T1_CreatedAt DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT UQ_T1Return UNIQUE (ClientId, TaxYear),
    CONSTRAINT FK_T1Return_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT FK_T1Return_TaxYear
        FOREIGN KEY (TaxYear) REFERENCES ref.TaxYear (TaxYear),
    CONSTRAINT FK_T1Return_Province
        FOREIGN KEY (ProvinceOfResidence) REFERENCES ref.Province (ProvinceCode),
    CONSTRAINT CK_T1Return_Status
        CHECK (FilingStatus IN (N'Draft', N'Ready', N'Filed', N'Assessed', N'Reassessed')),
    CONSTRAINT CK_T1Return_Income
        CHECK (EmploymentIncome >= 0 AND SelfEmploymentIncome >= 0
           AND PensionIncome    >= 0 AND OtherIncome >= 0),
    CONSTRAINT CK_T1Return_Deductions
        CHECK (RRSPDeduction >= 0 AND UnionDues >= 0 AND ChildCareExpenses >= 0
           AND OtherDeductions >= 0 AND LossCarryforward >= 0),
    -- A filed return must carry a filing date; a draft must not.
    CONSTRAINT CK_T1Return_FiledDate
        CHECK ((FilingStatus IN (N'Draft', N'Ready') AND DateFiled IS NULL)
            OR (FilingStatus IN (N'Filed', N'Assessed', N'Reassessed') AND DateFiled IS NOT NULL))
);
GO

/*--------------------------------------------------------------------------
  T2 - corporate income tax return. Keyed on the fiscal period, not a tax year,
  because a corporation's year end need not be December.
--------------------------------------------------------------------------*/
IF OBJECT_ID('tax.T2Return', 'U') IS NULL
CREATE TABLE tax.T2Return
(
    T2ReturnId              INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_T2Return PRIMARY KEY CLUSTERED,
    ClientId                INT            NOT NULL,
    FiscalYearStart         DATE           NOT NULL,
    FiscalYearEnd           DATE           NOT NULL,
    ProvinceOfOperation     CHAR(2)        NOT NULL,
    FilingStatus            NVARCHAR(20)   NOT NULL CONSTRAINT DF_T2Return_Status DEFAULT (N'Draft'),
    IsCCPC                  BIT            NOT NULL CONSTRAINT DF_T2_IsCCPC DEFAULT (1),

    GrossRevenue            DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T2_Revenue DEFAULT (0),
    TotalExpenses           DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T2_Expenses DEFAULT (0),
    NetIncomeForTax AS (GrossRevenue - TotalExpenses) PERSISTED NOT NULL,
    SmallBusinessDeduction  DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T2_SBD DEFAULT (0),
    NonCapitalLossApplied   DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T2_Loss DEFAULT (0),
    TaxableIncome AS (CASE WHEN GrossRevenue - TotalExpenses - NonCapitalLossApplied < 0
                           THEN CONVERT(DECIMAL(19, 2), 0)
                           ELSE GrossRevenue - TotalExpenses - NonCapitalLossApplied
                      END) PERSISTED NOT NULL,

    FederalTax              DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T2_FedTax  DEFAULT (0),
    ProvincialTax           DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T2_ProvTax DEFAULT (0),
    TotalTaxPayable AS (FederalTax + ProvincialTax) PERSISTED NOT NULL,
    InstallmentsPaid        DECIMAL(19, 2) NOT NULL CONSTRAINT DF_T2_Inst DEFAULT (0),
    BalanceOwing AS (FederalTax + ProvincialTax - InstallmentsPaid) PERSISTED NOT NULL,

    FilingDueDate           DATE           NOT NULL,
    DateFiled               DATE           NULL,
    CreatedAt               DATETIME2(3)   NOT NULL CONSTRAINT DF_T2_CreatedAt DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT UQ_T2Return UNIQUE (ClientId, FiscalYearEnd),
    CONSTRAINT FK_T2Return_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT FK_T2Return_Province
        FOREIGN KEY (ProvinceOfOperation) REFERENCES ref.Province (ProvinceCode),
    CONSTRAINT CK_T2Return_Period CHECK (FiscalYearEnd > FiscalYearStart),
    -- A tax year may not exceed 53 weeks.
    CONSTRAINT CK_T2Return_PeriodLength
        CHECK (DATEDIFF(DAY, FiscalYearStart, FiscalYearEnd) <= 371),
    CONSTRAINT CK_T2Return_Status
        CHECK (FilingStatus IN (N'Draft', N'Ready', N'Filed', N'Assessed', N'Reassessed')),
    CONSTRAINT CK_T2Return_Amounts
        CHECK (GrossRevenue >= 0 AND TotalExpenses >= 0 AND SmallBusinessDeduction >= 0)
);
GO

/*--------------------------------------------------------------------------
  Information slips.

  Slip carries the header, SlipBox the amounts. The composite FK on SlipBox
  reaches ref.SlipBoxDefinition so a T4 cannot be given a box that only exists
  on a T5; UQ_Slip_IdType exists solely to support the second composite FK back
  to the parent, keeping SlipTypeCode on the two tables in lockstep.
--------------------------------------------------------------------------*/
IF OBJECT_ID('tax.Slip', 'U') IS NULL
CREATE TABLE tax.Slip
(
    SlipId          INT           NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_Slip PRIMARY KEY CLUSTERED,
    ClientId        INT           NOT NULL,
    TaxYear         SMALLINT      NOT NULL,
    SlipTypeCode    NVARCHAR(10)  NOT NULL,
    IssuerName      NVARCHAR(150) NOT NULL,
    IssuerBusinessNumber CHAR(9)  NULL,
    SlipReference   NVARCHAR(40)  NOT NULL,
    ReceivedDate    DATE          NULL,
    IsAmended       BIT           NOT NULL CONSTRAINT DF_Slip_IsAmended DEFAULT (0),
    CONSTRAINT UQ_Slip UNIQUE (ClientId, TaxYear, SlipTypeCode, SlipReference),
    CONSTRAINT UQ_Slip_IdType UNIQUE (SlipId, SlipTypeCode),
    CONSTRAINT FK_Slip_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT FK_Slip_TaxYear
        FOREIGN KEY (TaxYear) REFERENCES ref.TaxYear (TaxYear),
    CONSTRAINT FK_Slip_SlipType
        FOREIGN KEY (SlipTypeCode) REFERENCES ref.SlipType (SlipTypeCode),
    CONSTRAINT CK_Slip_IssuerBn
        CHECK (IssuerBusinessNumber IS NULL
            OR IssuerBusinessNumber LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]')
);
GO

IF OBJECT_ID('tax.SlipBox', 'U') IS NULL
CREATE TABLE tax.SlipBox
(
    SlipId       INT            NOT NULL,
    SlipTypeCode NVARCHAR(10)   NOT NULL,
    BoxNumber    NVARCHAR(10)   NOT NULL,
    Amount       DECIMAL(19, 2) NOT NULL,
    CONSTRAINT PK_SlipBox PRIMARY KEY CLUSTERED (SlipId, BoxNumber),
    CONSTRAINT FK_SlipBox_Slip
        FOREIGN KEY (SlipId, SlipTypeCode)
        REFERENCES tax.Slip (SlipId, SlipTypeCode) ON DELETE CASCADE,
    CONSTRAINT FK_SlipBox_Definition
        FOREIGN KEY (SlipTypeCode, BoxNumber)
        REFERENCES ref.SlipBoxDefinition (SlipTypeCode, BoxNumber)
);
GO

/*--------------------------------------------------------------------------
  RRSP contributions. First-60-days contributions may be deducted in either
  the preceding year or the current one, so the flag matters.
--------------------------------------------------------------------------*/
IF OBJECT_ID('tax.RRSPContribution', 'U') IS NULL
CREATE TABLE tax.RRSPContribution
(
    RRSPContributionId INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_RRSPContribution PRIMARY KEY CLUSTERED,
    ClientId           INT            NOT NULL,
    TaxYear            SMALLINT       NOT NULL,
    ContributionDate   DATE           NOT NULL,
    Amount             DECIMAL(19, 2) NOT NULL,
    IsFirst60Days      BIT            NOT NULL CONSTRAINT DF_RRSP_First60 DEFAULT (0),
    IssuerName         NVARCHAR(150)  NOT NULL,
    CONSTRAINT FK_RRSP_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT FK_RRSP_TaxYear
        FOREIGN KEY (TaxYear) REFERENCES ref.TaxYear (TaxYear),
    CONSTRAINT CK_RRSP_Amount CHECK (Amount > 0)
);
GO

/*--------------------------------------------------------------------------
  GST/HST return. Line numbers match the GST34 return.
--------------------------------------------------------------------------*/
IF OBJECT_ID('tax.GSTHSTReturn', 'U') IS NULL
CREATE TABLE tax.GSTHSTReturn
(
    GSTHSTReturnId     INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_GSTHSTReturn PRIMARY KEY CLUSTERED,
    ClientId           INT            NOT NULL,
    PeriodStart        DATE           NOT NULL,
    PeriodEnd          DATE           NOT NULL,
    FrequencyCode      NVARCHAR(10)   NOT NULL,
    Line101Sales       DECIMAL(19, 2) NOT NULL CONSTRAINT DF_GST_101 DEFAULT (0),
    Line105TaxCollected DECIMAL(19, 2) NOT NULL CONSTRAINT DF_GST_105 DEFAULT (0),
    Line108InputTaxCredits DECIMAL(19, 2) NOT NULL CONSTRAINT DF_GST_108 DEFAULT (0),
    -- Line 109: net tax. Negative means a refund is owed to the registrant.
    Line109NetTax AS (Line105TaxCollected - Line108InputTaxCredits) PERSISTED NOT NULL,
    PaymentsMade       DECIMAL(19, 2) NOT NULL CONSTRAINT DF_GST_Payments DEFAULT (0),
    BalanceDue AS (Line105TaxCollected - Line108InputTaxCredits - PaymentsMade) PERSISTED NOT NULL,
    FilingDueDate      DATE           NOT NULL,
    FiledAt            DATETIME2(3)   NULL,
    Status             NVARCHAR(20)   NOT NULL CONSTRAINT DF_GST_Status DEFAULT (N'Open'),
    CONSTRAINT UQ_GSTHSTReturn UNIQUE (ClientId, PeriodStart),
    CONSTRAINT FK_GSTHSTReturn_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT FK_GSTHSTReturn_Frequency
        FOREIGN KEY (FrequencyCode) REFERENCES ref.FilingFrequency (FrequencyCode),
    CONSTRAINT CK_GSTHSTReturn_Period CHECK (PeriodEnd > PeriodStart),
    CONSTRAINT CK_GSTHSTReturn_Status
        CHECK (Status IN (N'Open', N'Filed', N'Paid', N'Assessed')),
    CONSTRAINT CK_GSTHSTReturn_Amounts
        CHECK (Line101Sales >= 0 AND Line105TaxCollected >= 0 AND Line108InputTaxCredits >= 0),
    CONSTRAINT CK_GSTHSTReturn_Filed
        CHECK ((Status = N'Open' AND FiledAt IS NULL) OR (Status <> N'Open' AND FiledAt IS NOT NULL))
);
GO

/*--------------------------------------------------------------------------
  Quarterly instalments.
--------------------------------------------------------------------------*/
IF OBJECT_ID('tax.Installment', 'U') IS NULL
CREATE TABLE tax.Installment
(
    InstallmentId INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_Installment PRIMARY KEY CLUSTERED,
    ClientId      INT            NOT NULL,
    TaxYear       SMALLINT       NOT NULL,
    DueDate       DATE           NOT NULL,
    AmountDue     DECIMAL(19, 2) NOT NULL,
    AmountPaid    DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Installment_Paid DEFAULT (0),
    PaidDate      DATE           NULL,
    CONSTRAINT UQ_Installment UNIQUE (ClientId, TaxYear, DueDate),
    CONSTRAINT FK_Installment_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT FK_Installment_TaxYear
        FOREIGN KEY (TaxYear) REFERENCES ref.TaxYear (TaxYear),
    CONSTRAINT CK_Installment_Amounts CHECK (AmountDue >= 0 AND AmountPaid >= 0),
    CONSTRAINT CK_Installment_PaidDate
        CHECK ((AmountPaid = 0 AND PaidDate IS NULL) OR (AmountPaid > 0 AND PaidDate IS NOT NULL))
);
GO

/*--------------------------------------------------------------------------
  Non-refundable credits actually claimed on a return.
--------------------------------------------------------------------------*/
IF OBJECT_ID('tax.CreditClaim', 'U') IS NULL
CREATE TABLE tax.CreditClaim
(
    CreditClaimId    INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_CreditClaim PRIMARY KEY CLUSTERED,
    T1ReturnId       INT            NOT NULL,
    TaxYear          SMALLINT       NOT NULL,
    JurisdictionCode CHAR(2)        NOT NULL,
    CreditCode       NVARCHAR(20)   NOT NULL,
    ClaimedAmount    DECIMAL(19, 2) NOT NULL,
    CONSTRAINT UQ_CreditClaim UNIQUE (T1ReturnId, JurisdictionCode, CreditCode),
    CONSTRAINT FK_CreditClaim_T1Return
        FOREIGN KEY (T1ReturnId) REFERENCES tax.T1Return (T1ReturnId) ON DELETE CASCADE,
    CONSTRAINT FK_CreditClaim_Credit
        FOREIGN KEY (TaxYear, JurisdictionCode, CreditCode)
        REFERENCES ref.NonRefundableCredit (TaxYear, JurisdictionCode, CreditCode),
    CONSTRAINT CK_CreditClaim_Amount CHECK (ClaimedAmount >= 0)
);
GO

/*--------------------------------------------------------------------------
  Assessment history. Append-only: every run of tax.usp_CalculateT1 writes a
  row, so a return's calculation history is reconstructable.
--------------------------------------------------------------------------*/
IF OBJECT_ID('tax.Assessment', 'U') IS NULL
CREATE TABLE tax.Assessment
(
    AssessmentId     INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_Assessment PRIMARY KEY CLUSTERED,
    T1ReturnId       INT            NOT NULL,
    AssessmentType   NVARCHAR(20)   NOT NULL,
    AssessedOn       DATETIME2(3)   NOT NULL CONSTRAINT DF_Assessment_On DEFAULT (SYSUTCDATETIME()),
    TaxableIncome    DECIMAL(19, 2) NOT NULL,
    FederalTax       DECIMAL(19, 2) NOT NULL,
    ProvincialTax    DECIMAL(19, 2) NOT NULL,
    TotalPayable     DECIMAL(19, 2) NOT NULL,
    BalanceOwing     DECIMAL(19, 2) NOT NULL,
    CalculationNotes NVARCHAR(400)  NULL,
    CONSTRAINT FK_Assessment_T1Return
        FOREIGN KEY (T1ReturnId) REFERENCES tax.T1Return (T1ReturnId) ON DELETE CASCADE,
    CONSTRAINT CK_Assessment_Type
        CHECK (AssessmentType IN (N'Original', N'Reassessment', N'Recalculation'))
);
GO

PRINT '004 tax tables ready.';
GO
