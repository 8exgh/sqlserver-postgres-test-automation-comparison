/*==============================================================================
  002 - Reference / lookup tables  [ref]

  Slow-moving data that the tax and payroll calculations are driven from. Rates
  live in tables rather than in code so that a calculation for 2023 keeps giving
  the 2023 answer after 2025 rates are added.
==============================================================================*/
USE CdnTaxPractice;
GO

/*--------------------------------------------------------------------------
  Provinces and territories.
--------------------------------------------------------------------------*/
IF OBJECT_ID('ref.Province', 'U') IS NULL
CREATE TABLE ref.Province
(
    ProvinceCode  CHAR(2)      NOT NULL CONSTRAINT PK_Province PRIMARY KEY CLUSTERED,
    ProvinceName  NVARCHAR(50) NOT NULL,
    IsTerritory   BIT          NOT NULL CONSTRAINT DF_Province_IsTerritory DEFAULT (0),
    SortOrder     TINYINT      NOT NULL,
    CONSTRAINT UQ_Province_Name  UNIQUE (ProvinceName),
    CONSTRAINT CK_Province_Code  CHECK (ProvinceCode = UPPER(ProvinceCode))
);
GO

/*--------------------------------------------------------------------------
  Taxing jurisdictions: the federal government plus each province/territory.
  Gives ref.TaxBracket a real foreign key instead of a magic 'CA' string.
--------------------------------------------------------------------------*/
IF OBJECT_ID('ref.Jurisdiction', 'U') IS NULL
CREATE TABLE ref.Jurisdiction
(
    JurisdictionCode CHAR(2)      NOT NULL CONSTRAINT PK_Jurisdiction PRIMARY KEY CLUSTERED,
    JurisdictionName NVARCHAR(60) NOT NULL,
    IsFederal        BIT          NOT NULL CONSTRAINT DF_Jurisdiction_IsFederal DEFAULT (0),
    ProvinceCode     CHAR(2)      NULL,
    CONSTRAINT FK_Jurisdiction_Province
        FOREIGN KEY (ProvinceCode) REFERENCES ref.Province (ProvinceCode),
    -- Federal rows have no province; provincial rows must name one.
    CONSTRAINT CK_Jurisdiction_Province
        CHECK ((IsFederal = 1 AND ProvinceCode IS NULL)
            OR (IsFederal = 0 AND ProvinceCode IS NOT NULL))
);
GO

/*--------------------------------------------------------------------------
  Sales tax rates, date-ranged. A NULL EffectiveTo means "still in force".
  Nova Scotia's 2025 HST reduction is why this is a range table and not a
  single rate column on ref.Province.
--------------------------------------------------------------------------*/
IF OBJECT_ID('ref.SalesTaxRate', 'U') IS NULL
CREATE TABLE ref.SalesTaxRate
(
    SalesTaxRateId INT           NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_SalesTaxRate PRIMARY KEY CLUSTERED,
    ProvinceCode   CHAR(2)       NOT NULL,
    EffectiveFrom  DATE          NOT NULL,
    EffectiveTo    DATE          NULL,
    GSTRate        DECIMAL(9, 5) NOT NULL CONSTRAINT DF_SalesTaxRate_GST DEFAULT (0),
    HSTRate        DECIMAL(9, 5) NOT NULL CONSTRAINT DF_SalesTaxRate_HST DEFAULT (0),
    PSTRate        DECIMAL(9, 5) NOT NULL CONSTRAINT DF_SalesTaxRate_PST DEFAULT (0),
    QSTRate        DECIMAL(9, 5) NOT NULL CONSTRAINT DF_SalesTaxRate_QST DEFAULT (0),
    -- Persisted computed column: the combined rate is derived, never entered.
    CombinedRate   AS (GSTRate + HSTRate + PSTRate + QSTRate) PERSISTED NOT NULL,
    CONSTRAINT FK_SalesTaxRate_Province
        FOREIGN KEY (ProvinceCode) REFERENCES ref.Province (ProvinceCode),
    CONSTRAINT UQ_SalesTaxRate_Province_From UNIQUE (ProvinceCode, EffectiveFrom),
    CONSTRAINT CK_SalesTaxRate_Range  CHECK (EffectiveTo IS NULL OR EffectiveTo > EffectiveFrom),
    -- A province charges either HST or GST(+PST/QST), never HST alongside GST.
    CONSTRAINT CK_SalesTaxRate_HstXorGst
        CHECK ((HSTRate > 0 AND GSTRate = 0 AND PSTRate = 0 AND QSTRate = 0)
            OR (HSTRate = 0 AND GSTRate > 0)),
    CONSTRAINT CK_SalesTaxRate_NonNegative
        CHECK (GSTRate >= 0 AND HSTRate >= 0 AND PSTRate >= 0 AND QSTRate >= 0)
);
GO

/*--------------------------------------------------------------------------
  Tax years. IsLocked marks a year whose returns must no longer be recalculated.
--------------------------------------------------------------------------*/
IF OBJECT_ID('ref.TaxYear', 'U') IS NULL
CREATE TABLE ref.TaxYear
(
    TaxYear               SMALLINT       NOT NULL CONSTRAINT PK_TaxYear PRIMARY KEY CLUSTERED,
    T1FilingDeadline      DATE           NOT NULL,
    SelfEmployedDeadline  DATE           NOT NULL,
    RRSPDeadline          DATE           NOT NULL,
    InstallmentThreshold  DECIMAL(19, 2) NOT NULL CONSTRAINT DF_TaxYear_Threshold DEFAULT (3000.00),
    IsLocked              BIT            NOT NULL CONSTRAINT DF_TaxYear_IsLocked  DEFAULT (0),
    CONSTRAINT CK_TaxYear_Range     CHECK (TaxYear BETWEEN 1990 AND 2100),
    CONSTRAINT CK_TaxYear_Deadlines CHECK (SelfEmployedDeadline >= T1FilingDeadline)
);
GO

/*--------------------------------------------------------------------------
  Progressive tax brackets, one row per bracket per jurisdiction per year.
  UpperBound NULL = top bracket. tax.fn_FederalTax / fn_ProvincialTax walk
  these in Ordinal order.
--------------------------------------------------------------------------*/
IF OBJECT_ID('ref.TaxBracket', 'U') IS NULL
CREATE TABLE ref.TaxBracket
(
    TaxBracketId     INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_TaxBracket PRIMARY KEY CLUSTERED,
    TaxYear          SMALLINT       NOT NULL,
    JurisdictionCode CHAR(2)        NOT NULL,
    Ordinal          TINYINT        NOT NULL,
    LowerBound       DECIMAL(19, 2) NOT NULL,
    UpperBound       DECIMAL(19, 2) NULL,
    Rate             DECIMAL(9, 6)  NOT NULL,
    CONSTRAINT FK_TaxBracket_TaxYear
        FOREIGN KEY (TaxYear) REFERENCES ref.TaxYear (TaxYear),
    CONSTRAINT FK_TaxBracket_Jurisdiction
        FOREIGN KEY (JurisdictionCode) REFERENCES ref.Jurisdiction (JurisdictionCode),
    CONSTRAINT UQ_TaxBracket UNIQUE (TaxYear, JurisdictionCode, Ordinal),
    CONSTRAINT CK_TaxBracket_Bounds CHECK (UpperBound IS NULL OR UpperBound > LowerBound),
    CONSTRAINT CK_TaxBracket_Rate   CHECK (Rate >= 0 AND Rate <= 1),
    CONSTRAINT CK_TaxBracket_Lower  CHECK (LowerBound >= 0)
);
GO

/*--------------------------------------------------------------------------
  CPP / EI parameters. One row per year drives every payroll calculation.
--------------------------------------------------------------------------*/
IF OBJECT_ID('ref.PayrollRate', 'U') IS NULL
CREATE TABLE ref.PayrollRate
(
    TaxYear                SMALLINT       NOT NULL
        CONSTRAINT PK_PayrollRate PRIMARY KEY CLUSTERED,
    -- CPP base tier
    CPPRate                DECIMAL(9, 6)  NOT NULL,
    CPPBasicExemption      DECIMAL(19, 2) NOT NULL,
    YMPE                   DECIMAL(19, 2) NOT NULL,  -- yearly maximum pensionable earnings
    -- CPP2 (second additional) tier, introduced 2024; zero rate disables it.
    CPP2Rate               DECIMAL(9, 6)  NOT NULL CONSTRAINT DF_PayrollRate_CPP2Rate DEFAULT (0),
    YAMPE                  DECIMAL(19, 2) NOT NULL CONSTRAINT DF_PayrollRate_YAMPE    DEFAULT (0),
    -- EI
    EIRate                 DECIMAL(9, 6)  NOT NULL,
    EIRateQuebec           DECIMAL(9, 6)  NOT NULL,
    EIMaxInsurableEarnings DECIMAL(19, 2) NOT NULL,
    EmployerEIMultiplier   DECIMAL(9, 4)  NOT NULL CONSTRAINT DF_PayrollRate_EIMult DEFAULT (1.4),
    CONSTRAINT FK_PayrollRate_TaxYear
        FOREIGN KEY (TaxYear) REFERENCES ref.TaxYear (TaxYear),
    CONSTRAINT CK_PayrollRate_Ympe   CHECK (YMPE > CPPBasicExemption),
    CONSTRAINT CK_PayrollRate_Yampe  CHECK (YAMPE = 0 OR YAMPE >= YMPE),
    CONSTRAINT CK_PayrollRate_Rates
        CHECK (CPPRate BETWEEN 0 AND 1 AND CPP2Rate BETWEEN 0 AND 1
           AND EIRate BETWEEN 0 AND 1 AND EIRateQuebec BETWEEN 0 AND 1)
);
GO

/*--------------------------------------------------------------------------
  Information slips and their boxes. tax.Slip stores boxes as rows against
  these definitions, which is what lets one table hold T4s and T5s alike.
--------------------------------------------------------------------------*/
IF OBJECT_ID('ref.SlipType', 'U') IS NULL
CREATE TABLE ref.SlipType
(
    SlipTypeCode NVARCHAR(10)  NOT NULL CONSTRAINT PK_SlipType PRIMARY KEY CLUSTERED,
    Description  NVARCHAR(100) NOT NULL,
    IssuedBy     NVARCHAR(60)  NOT NULL,
    IsActive     BIT           NOT NULL CONSTRAINT DF_SlipType_IsActive DEFAULT (1)
);
GO

IF OBJECT_ID('ref.SlipBoxDefinition', 'U') IS NULL
CREATE TABLE ref.SlipBoxDefinition
(
    SlipTypeCode   NVARCHAR(10) NOT NULL,
    BoxNumber      NVARCHAR(10) NOT NULL,
    Label          NVARCHAR(100) NOT NULL,
    -- Maps a box onto the income line it feeds on the T1.
    IncomeCategory NVARCHAR(30) NOT NULL,
    CONSTRAINT PK_SlipBoxDefinition PRIMARY KEY CLUSTERED (SlipTypeCode, BoxNumber),
    CONSTRAINT FK_SlipBoxDefinition_SlipType
        FOREIGN KEY (SlipTypeCode) REFERENCES ref.SlipType (SlipTypeCode)
        ON DELETE CASCADE,
    CONSTRAINT CK_SlipBoxDefinition_Category
        CHECK (IncomeCategory IN ('Employment', 'Investment', 'SelfEmployment',
                                  'Pension', 'Other', 'Deduction', 'TaxWithheld',
                                  'CPP', 'EI', 'NonIncome'))
);
GO

/*--------------------------------------------------------------------------
  Chart-of-accounts classification. IsNominal marks the revenue/expense types
  that acct.usp_CloseFiscalYear rolls into retained earnings.
--------------------------------------------------------------------------*/
IF OBJECT_ID('ref.AccountType', 'U') IS NULL
CREATE TABLE ref.AccountType
(
    AccountTypeCode NVARCHAR(20) NOT NULL CONSTRAINT PK_AccountType PRIMARY KEY CLUSTERED,
    Description     NVARCHAR(60) NOT NULL,
    NormalBalance   CHAR(1)      NOT NULL,  -- 'D'ebit or 'C'redit
    IsNominal       BIT          NOT NULL,  -- closed out at year end
    BalanceSheetOrder TINYINT    NOT NULL,
    CONSTRAINT CK_AccountType_NormalBalance CHECK (NormalBalance IN ('D', 'C'))
);
GO

/*--------------------------------------------------------------------------
  Statutory holidays. JurisdictionCode 'CA' = national. Feeds
  util.fn_BusinessDaysBetween, which is used for filing-deadline arithmetic.
--------------------------------------------------------------------------*/
IF OBJECT_ID('ref.StatutoryHoliday', 'U') IS NULL
CREATE TABLE ref.StatutoryHoliday
(
    StatutoryHolidayId INT          NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_StatutoryHoliday PRIMARY KEY CLUSTERED,
    HolidayDate        DATE         NOT NULL,
    HolidayName        NVARCHAR(60) NOT NULL,
    JurisdictionCode   CHAR(2)      NOT NULL,
    CONSTRAINT FK_StatutoryHoliday_Jurisdiction
        FOREIGN KEY (JurisdictionCode) REFERENCES ref.Jurisdiction (JurisdictionCode),
    CONSTRAINT UQ_StatutoryHoliday UNIQUE (HolidayDate, JurisdictionCode)
);
GO

/*--------------------------------------------------------------------------
  Non-refundable credits, per year and jurisdiction. The claimable amount is
  the lesser of MaxAmount and what the taxpayer actually qualifies for.
--------------------------------------------------------------------------*/
IF OBJECT_ID('ref.NonRefundableCredit', 'U') IS NULL
CREATE TABLE ref.NonRefundableCredit
(
    CreditCode       NVARCHAR(20)   NOT NULL,
    TaxYear          SMALLINT       NOT NULL,
    JurisdictionCode CHAR(2)        NOT NULL,
    Description      NVARCHAR(100)  NOT NULL,
    MaxAmount        DECIMAL(19, 2) NOT NULL,
    -- Credits are claimed at the lowest bracket rate, stored explicitly so a
    -- historical year keeps its own rate.
    CreditRate       DECIMAL(9, 6)  NOT NULL,
    CONSTRAINT PK_NonRefundableCredit
        PRIMARY KEY CLUSTERED (TaxYear, JurisdictionCode, CreditCode),
    CONSTRAINT FK_NonRefundableCredit_TaxYear
        FOREIGN KEY (TaxYear) REFERENCES ref.TaxYear (TaxYear),
    CONSTRAINT FK_NonRefundableCredit_Jurisdiction
        FOREIGN KEY (JurisdictionCode) REFERENCES ref.Jurisdiction (JurisdictionCode),
    CONSTRAINT CK_NonRefundableCredit_Amount CHECK (MaxAmount >= 0)
);
GO

/*--------------------------------------------------------------------------
  GST/HST filing frequency.
--------------------------------------------------------------------------*/
IF OBJECT_ID('ref.FilingFrequency', 'U') IS NULL
CREATE TABLE ref.FilingFrequency
(
    FrequencyCode  NVARCHAR(10) NOT NULL CONSTRAINT PK_FilingFrequency PRIMARY KEY CLUSTERED,
    Description    NVARCHAR(40) NOT NULL,
    PeriodsPerYear TINYINT      NOT NULL,
    CONSTRAINT CK_FilingFrequency_Periods CHECK (PeriodsPerYear IN (1, 4, 12))
);
GO

PRINT '002 reference tables ready.';
GO
