/*==============================================================================
  006 - Payroll and audit  [payroll] [audit]

  Payroll is run for corporate clients of the practice: the client is the
  employer, payroll.Employee holds that employer's staff.
==============================================================================*/
USE CdnTaxPractice;
GO

/*--------------------------------------------------------------------------
  Employees of a client-employer. TD1 amounts drive the withholding estimate
  in payroll.usp_RunPayroll.
--------------------------------------------------------------------------*/
IF OBJECT_ID('payroll.Employee', 'U') IS NULL
CREATE TABLE payroll.Employee
(
    EmployeeId          INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_Employee PRIMARY KEY CLUSTERED,
    EmployerClientId    INT            NOT NULL,
    EmployeeNumber      NVARCHAR(20)   NOT NULL,
    FirstName           NVARCHAR(50)   NOT NULL,
    LastName            NVARCHAR(50)   NOT NULL,
    SIN                 CHAR(9)        NOT NULL,
    ProvinceOfEmployment CHAR(2)       NOT NULL,
    HireDate            DATE           NOT NULL,
    TerminationDate     DATE           NULL,
    PayFrequency        NVARCHAR(20)   NOT NULL,
    AnnualSalary        DECIMAL(19, 2) NOT NULL,
    TD1FederalAmount    DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Employee_TD1Fed  DEFAULT (0),
    TD1ProvincialAmount DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Employee_TD1Prov DEFAULT (0),
    IsActive            BIT            NOT NULL CONSTRAINT DF_Employee_IsActive DEFAULT (1),
    CONSTRAINT UQ_Employee UNIQUE (EmployerClientId, EmployeeNumber),
    CONSTRAINT FK_Employee_Client
        FOREIGN KEY (EmployerClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT FK_Employee_Province
        FOREIGN KEY (ProvinceOfEmployment) REFERENCES ref.Province (ProvinceCode),
    CONSTRAINT CK_Employee_Sin
        CHECK (SIN LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'),
    CONSTRAINT CK_Employee_PayFrequency
        CHECK (PayFrequency IN (N'Weekly', N'BiWeekly', N'SemiMonthly', N'Monthly')),
    CONSTRAINT CK_Employee_Salary CHECK (AnnualSalary >= 0),
    CONSTRAINT CK_Employee_Termination
        CHECK (TerminationDate IS NULL OR TerminationDate >= HireDate)
);
GO

/*--------------------------------------------------------------------------
  Pay periods per employer per year.
--------------------------------------------------------------------------*/
IF OBJECT_ID('payroll.PayPeriod', 'U') IS NULL
CREATE TABLE payroll.PayPeriod
(
    PayPeriodId  INT      NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_PayPeriod PRIMARY KEY CLUSTERED,
    ClientId     INT      NOT NULL,
    TaxYear      SMALLINT NOT NULL,
    PeriodNumber SMALLINT NOT NULL,
    StartDate    DATE     NOT NULL,
    EndDate      DATE     NOT NULL,
    PayDate      DATE     NOT NULL,
    IsProcessed  BIT      NOT NULL CONSTRAINT DF_PayPeriod_IsProcessed DEFAULT (0),
    CONSTRAINT UQ_PayPeriod UNIQUE (ClientId, TaxYear, PeriodNumber),
    CONSTRAINT FK_PayPeriod_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT FK_PayPeriod_TaxYear
        FOREIGN KEY (TaxYear) REFERENCES ref.TaxYear (TaxYear),
    CONSTRAINT CK_PayPeriod_Range   CHECK (EndDate > StartDate),
    CONSTRAINT CK_PayPeriod_PayDate CHECK (PayDate >= EndDate),
    CONSTRAINT CK_PayPeriod_Number  CHECK (PeriodNumber BETWEEN 1 AND 53)
);
GO

/*--------------------------------------------------------------------------
  Paystubs. NetPay is the only computed column here; every deduction is a
  stored fact produced by payroll.usp_RunPayroll.
--------------------------------------------------------------------------*/
IF OBJECT_ID('payroll.Paystub', 'U') IS NULL
CREATE TABLE payroll.Paystub
(
    PaystubId             INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_Paystub PRIMARY KEY CLUSTERED,
    PayPeriodId           INT            NOT NULL,
    EmployeeId            INT            NOT NULL,
    GrossPay              DECIMAL(19, 2) NOT NULL,
    CPPDeducted           DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Paystub_CPP   DEFAULT (0),
    CPP2Deducted          DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Paystub_CPP2  DEFAULT (0),
    EIDeducted            DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Paystub_EI    DEFAULT (0),
    FederalTaxDeducted    DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Paystub_FedTax  DEFAULT (0),
    ProvincialTaxDeducted DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Paystub_ProvTax DEFAULT (0),
    OtherDeductions       DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Paystub_Other   DEFAULT (0),
    NetPay AS (GrossPay - CPPDeducted - CPP2Deducted - EIDeducted
               - FederalTaxDeducted - ProvincialTaxDeducted
               - OtherDeductions) PERSISTED NOT NULL,
    CONSTRAINT UQ_Paystub UNIQUE (PayPeriodId, EmployeeId),
    CONSTRAINT FK_Paystub_PayPeriod
        FOREIGN KEY (PayPeriodId) REFERENCES payroll.PayPeriod (PayPeriodId) ON DELETE CASCADE,
    -- NO ACTION: keeps a single cascade path into this table.
    CONSTRAINT FK_Paystub_Employee
        FOREIGN KEY (EmployeeId) REFERENCES payroll.Employee (EmployeeId),
    CONSTRAINT CK_Paystub_NonNegative
        CHECK (GrossPay >= 0 AND CPPDeducted >= 0 AND CPP2Deducted >= 0 AND EIDeducted >= 0
           AND FederalTaxDeducted >= 0 AND ProvincialTaxDeducted >= 0 AND OtherDeductions >= 0)
);
GO

/*--------------------------------------------------------------------------
  Employer source-deduction remittance (the PD7A). Employer CPP matches the
  employee share; employer EI is 1.4x by default.
--------------------------------------------------------------------------*/
IF OBJECT_ID('payroll.Remittance', 'U') IS NULL
CREATE TABLE payroll.Remittance
(
    RemittanceId       INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_Remittance PRIMARY KEY CLUSTERED,
    ClientId           INT            NOT NULL,
    PeriodEnd          DATE           NOT NULL,
    DueDate            DATE           NOT NULL,
    CPPEmployee        DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Remit_CPPEe DEFAULT (0),
    CPPEmployer        DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Remit_CPPEr DEFAULT (0),
    EIEmployee         DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Remit_EIEe  DEFAULT (0),
    EIEmployer         DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Remit_EIEr  DEFAULT (0),
    IncomeTaxWithheld  DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Remit_Tax   DEFAULT (0),
    TotalRemittance AS (CPPEmployee + CPPEmployer + EIEmployee + EIEmployer
                        + IncomeTaxWithheld) PERSISTED NOT NULL,
    RemittedDate       DATE           NULL,
    ConfirmationNumber NVARCHAR(40)   NULL,
    CONSTRAINT UQ_Remittance UNIQUE (ClientId, PeriodEnd),
    CONSTRAINT FK_Remittance_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT CK_Remittance_Due CHECK (DueDate > PeriodEnd),
    CONSTRAINT CK_Remittance_Amounts
        CHECK (CPPEmployee >= 0 AND CPPEmployer >= 0 AND EIEmployee >= 0
           AND EIEmployer >= 0 AND IncomeTaxWithheld >= 0)
);
GO

/*--------------------------------------------------------------------------
  Generic change log, written by client.tr_Client_Audit. Old/new row images
  are stored as JSON and shredded back out by audit.vw_RecentChanges.
--------------------------------------------------------------------------*/
IF OBJECT_ID('audit.ChangeLog', 'U') IS NULL
CREATE TABLE audit.ChangeLog
(
    ChangeLogId     BIGINT         NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_ChangeLog PRIMARY KEY CLUSTERED,
    SchemaName      SYSNAME        NOT NULL,
    TableName       SYSNAME        NOT NULL,
    PrimaryKeyValue NVARCHAR(100)  NOT NULL,
    Operation       CHAR(1)        NOT NULL,
    ChangedBy       NVARCHAR(128)  NOT NULL CONSTRAINT DF_ChangeLog_By DEFAULT (SUSER_SNAME()),
    ChangedAt       DATETIME2(3)   NOT NULL CONSTRAINT DF_ChangeLog_At DEFAULT (SYSUTCDATETIME()),
    OldValues       NVARCHAR(MAX)  NULL,
    NewValues       NVARCHAR(MAX)  NULL,
    CONSTRAINT CK_ChangeLog_Operation CHECK (Operation IN ('I', 'U', 'D')),
    -- Guarantees the columns really do hold JSON before OPENJSON reads them.
    CONSTRAINT CK_ChangeLog_OldJson CHECK (OldValues IS NULL OR ISJSON(OldValues) = 1),
    CONSTRAINT CK_ChangeLog_NewJson CHECK (NewValues IS NULL OR ISJSON(NewValues) = 1),
    CONSTRAINT CK_ChangeLog_Payload
        CHECK ((Operation = 'I' AND NewValues IS NOT NULL AND OldValues IS NULL)
            OR (Operation = 'U' AND NewValues IS NOT NULL AND OldValues IS NOT NULL)
            OR (Operation = 'D' AND NewValues IS NULL     AND OldValues IS NOT NULL))
);
GO

/*--------------------------------------------------------------------------
  Status transitions on a T1 return, written by tax.tr_T1Return_StatusHistory.
--------------------------------------------------------------------------*/
IF OBJECT_ID('audit.ReturnStatusHistory', 'U') IS NULL
CREATE TABLE audit.ReturnStatusHistory
(
    ReturnStatusHistoryId INT          NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_ReturnStatusHistory PRIMARY KEY CLUSTERED,
    T1ReturnId            INT          NOT NULL,
    OldStatus             NVARCHAR(20) NOT NULL,
    NewStatus             NVARCHAR(20) NOT NULL,
    ChangedAt             DATETIME2(3) NOT NULL
        CONSTRAINT DF_ReturnStatusHistory_At DEFAULT (SYSUTCDATETIME()),
    ChangedBy             NVARCHAR(128) NOT NULL
        CONSTRAINT DF_ReturnStatusHistory_By DEFAULT (SUSER_SNAME()),
    CONSTRAINT FK_ReturnStatusHistory_T1Return
        FOREIGN KEY (T1ReturnId) REFERENCES tax.T1Return (T1ReturnId) ON DELETE CASCADE,
    CONSTRAINT CK_ReturnStatusHistory_Changed CHECK (OldStatus <> NewStatus)
);
GO

PRINT '006 payroll and audit tables ready.';
GO
