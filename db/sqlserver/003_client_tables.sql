/*==============================================================================
  003 - The practice and its clients  [client]

  A client is either an individual (T1) or a corporation (T2). Rather than split
  into two tables, a discriminator plus CHECK constraints keeps the one-to-many
  relationships (addresses, engagements, invoices) single-headed.
==============================================================================*/
USE CdnTaxPractice;
GO

/*--------------------------------------------------------------------------
  Staff at the practice who own engagements.
--------------------------------------------------------------------------*/
IF OBJECT_ID('client.Practitioner', 'U') IS NULL
CREATE TABLE client.Practitioner
(
    PractitionerId INT           NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_Practitioner PRIMARY KEY CLUSTERED,
    FullName       NVARCHAR(100) NOT NULL,
    Designation    NVARCHAR(20)  NULL,          -- CPA, CPA/CA, CPA/CGA ...
    Email          NVARCHAR(150) NOT NULL,
    IsPartner      BIT           NOT NULL CONSTRAINT DF_Practitioner_IsPartner DEFAULT (0),
    IsActive       BIT           NOT NULL CONSTRAINT DF_Practitioner_IsActive  DEFAULT (1),
    CONSTRAINT UQ_Practitioner_Email UNIQUE (Email)
);
GO

/*--------------------------------------------------------------------------
  Clients.

  SIN and BusinessNumber are nullable because only one applies to any given
  client; uniqueness is therefore enforced by filtered unique indexes in 007
  rather than by UNIQUE constraints (which would collide on multiple NULLs in
  some engines and are awkward to port).
--------------------------------------------------------------------------*/
IF OBJECT_ID('client.Client', 'U') IS NULL
CREATE TABLE client.Client
(
    ClientId          INT           NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_Client PRIMARY KEY CLUSTERED,
    ClientCode        NVARCHAR(20)  NOT NULL,
    ClientType        CHAR(1)       NOT NULL,   -- 'I'ndividual or 'C'orporation
    -- Individuals
    FirstName         NVARCHAR(50)  NULL,
    LastName          NVARCHAR(50)  NULL,
    DateOfBirth       DATE          NULL,
    SIN               CHAR(9)       NULL,
    MaritalStatus     NVARCHAR(20)  NULL,
    -- Corporations
    LegalName         NVARCHAR(150) NULL,
    IncorporationDate DATE          NULL,
    BusinessNumber    CHAR(9)       NULL,
    FiscalYearEndMonth TINYINT      NULL,
    -- Common
    ProvinceCode      CHAR(2)       NOT NULL,
    OnboardedDate     DATE          NOT NULL,
    IsActive          BIT           NOT NULL CONSTRAINT DF_Client_IsActive DEFAULT (1),
    -- Persisted computed column: one display label regardless of client type.
    DisplayName       AS (CASE WHEN ClientType = 'C'
                              THEN ISNULL(LegalName, N'')
                              ELSE CONCAT(ISNULL(LastName, N''), N', ', ISNULL(FirstName, N''))
                         END) PERSISTED NOT NULL,
    CreatedAt         DATETIME2(3)  NOT NULL CONSTRAINT DF_Client_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt         DATETIME2(3)  NULL,
    -- Optimistic concurrency token for the upsert procedure.
    [RowVersion]      ROWVERSION    NOT NULL,

    CONSTRAINT UQ_Client_ClientCode UNIQUE (ClientCode),
    CONSTRAINT FK_Client_Province
        FOREIGN KEY (ProvinceCode) REFERENCES ref.Province (ProvinceCode),
    CONSTRAINT CK_Client_Type CHECK (ClientType IN ('I', 'C')),
    -- An individual needs a name and date of birth; a corporation needs a legal
    -- name and an incorporation date. Neither may carry the other's fields.
    CONSTRAINT CK_Client_TypeShape CHECK
    (
        (ClientType = 'I'
            AND FirstName IS NOT NULL AND LastName IS NOT NULL AND DateOfBirth IS NOT NULL
            AND LegalName IS NULL AND IncorporationDate IS NULL AND BusinessNumber IS NULL
            AND FiscalYearEndMonth IS NULL)
     OR (ClientType = 'C'
            AND LegalName IS NOT NULL AND IncorporationDate IS NOT NULL
            AND FiscalYearEndMonth IS NOT NULL
            AND FirstName IS NULL AND LastName IS NULL AND DateOfBirth IS NULL
            AND SIN IS NULL AND MaritalStatus IS NULL)
    ),
    CONSTRAINT CK_Client_SinDigits
        CHECK (SIN IS NULL OR SIN LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'),
    CONSTRAINT CK_Client_BnDigits
        CHECK (BusinessNumber IS NULL
            OR BusinessNumber LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'),
    CONSTRAINT CK_Client_FyeMonth
        CHECK (FiscalYearEndMonth IS NULL OR FiscalYearEndMonth BETWEEN 1 AND 12),
    CONSTRAINT CK_Client_MaritalStatus
        CHECK (MaritalStatus IS NULL
            OR MaritalStatus IN (N'Single', N'Married', N'Common-law',
                                 N'Separated', N'Divorced', N'Widowed'))
);
GO

/*--------------------------------------------------------------------------
  Addresses. Cascade delete: an address has no meaning without its client.
--------------------------------------------------------------------------*/
IF OBJECT_ID('client.ClientAddress', 'U') IS NULL
CREATE TABLE client.ClientAddress
(
    AddressId    INT           NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_ClientAddress PRIMARY KEY CLUSTERED,
    ClientId     INT           NOT NULL,
    AddressType  NVARCHAR(20)  NOT NULL CONSTRAINT DF_ClientAddress_Type DEFAULT (N'Mailing'),
    Line1        NVARCHAR(150) NOT NULL,
    Line2        NVARCHAR(150) NULL,
    City         NVARCHAR(80)  NOT NULL,
    ProvinceCode CHAR(2)       NOT NULL,
    PostalCode   CHAR(7)       NOT NULL,
    IsPrimary    BIT           NOT NULL CONSTRAINT DF_ClientAddress_IsPrimary DEFAULT (0),
    CONSTRAINT FK_ClientAddress_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT FK_ClientAddress_Province
        FOREIGN KEY (ProvinceCode) REFERENCES ref.Province (ProvinceCode),
    -- Canadian postal codes: A1A 1A1
    CONSTRAINT CK_ClientAddress_PostalCode
        CHECK (PostalCode LIKE '[A-Z][0-9][A-Z] [0-9][A-Z][0-9]'),
    CONSTRAINT CK_ClientAddress_Type
        CHECK (AddressType IN (N'Mailing', N'Physical', N'RegisteredOffice'))
);
GO

/*--------------------------------------------------------------------------
  Contact points.
--------------------------------------------------------------------------*/
IF OBJECT_ID('client.ClientContact', 'U') IS NULL
CREATE TABLE client.ClientContact
(
    ContactId    INT           NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_ClientContact PRIMARY KEY CLUSTERED,
    ClientId     INT           NOT NULL,
    ContactType  NVARCHAR(10)  NOT NULL,
    ContactValue NVARCHAR(150) NOT NULL,
    IsPrimary    BIT           NOT NULL CONSTRAINT DF_ClientContact_IsPrimary DEFAULT (0),
    CONSTRAINT FK_ClientContact_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT CK_ClientContact_Type CHECK (ContactType IN (N'Email', N'Phone', N'Mobile', N'Fax')),
    CONSTRAINT CK_ClientContact_Email
        CHECK (ContactType <> N'Email' OR ContactValue LIKE '%_@_%._%')
);
GO

/*--------------------------------------------------------------------------
  Engagements: a unit of billable work for a client in a tax year.

  NO ACTION on the practitioner FK on purpose - deleting a practitioner who
  still owns engagements should fail loudly rather than orphan or cascade.
--------------------------------------------------------------------------*/
IF OBJECT_ID('client.Engagement', 'U') IS NULL
CREATE TABLE client.Engagement
(
    EngagementId   INT            NOT NULL IDENTITY (1, 1)
        CONSTRAINT PK_Engagement PRIMARY KEY CLUSTERED,
    ClientId       INT            NOT NULL,
    TaxYear        SMALLINT       NOT NULL,
    ServiceType    NVARCHAR(30)   NOT NULL,
    PractitionerId INT            NOT NULL,
    Status         NVARCHAR(20)   NOT NULL CONSTRAINT DF_Engagement_Status DEFAULT (N'Open'),
    FeeQuoted      DECIMAL(19, 2) NOT NULL CONSTRAINT DF_Engagement_FeeQuoted DEFAULT (0),
    FeeBilled      DECIMAL(19, 2) NULL,
    StartedOn      DATE           NOT NULL,
    CompletedOn    DATE           NULL,
    CONSTRAINT FK_Engagement_Client
        FOREIGN KEY (ClientId) REFERENCES client.Client (ClientId) ON DELETE CASCADE,
    CONSTRAINT FK_Engagement_TaxYear
        FOREIGN KEY (TaxYear) REFERENCES ref.TaxYear (TaxYear),
    CONSTRAINT FK_Engagement_Practitioner
        FOREIGN KEY (PractitionerId) REFERENCES client.Practitioner (PractitionerId),
    CONSTRAINT UQ_Engagement UNIQUE (ClientId, TaxYear, ServiceType),
    CONSTRAINT CK_Engagement_Service
        CHECK (ServiceType IN (N'T1', N'T2', N'GSTHST', N'Payroll',
                               N'Bookkeeping', N'Review', N'Advisory')),
    CONSTRAINT CK_Engagement_Status
        CHECK (Status IN (N'Open', N'InProgress', N'AwaitingClient', N'Filed', N'Closed')),
    CONSTRAINT CK_Engagement_Dates  CHECK (CompletedOn IS NULL OR CompletedOn >= StartedOn),
    CONSTRAINT CK_Engagement_Fees   CHECK (FeeQuoted >= 0 AND (FeeBilled IS NULL OR FeeBilled >= 0))
);
GO

PRINT '003 client tables ready.';
GO
