/*==============================================================================
  021 - Sample data seed

  Everything here is deterministic: no NEWID(), no RAND(), and no GETDATE() in
  any stored value. Dates are literals or derived from literals, so an
  assertion written against this data gives the same answer next month.

  All SINs and Business Numbers below are synthetic values that satisfy the
  mod-10 check digit - they are not real identifiers belonging to anyone.

  Re-runnability: the whole file is guarded on whether any client exists. A
  second run is a no-op rather than a duplicate, so the end state is the same.
  To rebuild from nothing, use scripts/reset-sqlserver.sh.

  Where a procedure exists to create something, the seed calls it rather than
  inserting directly - so loading the fixture also exercises usp_ImportSlips,
  usp_PostJournalEntry, usp_GenerateInvoice, usp_FileGSTHSTReturn,
  usp_RunPayroll, usp_CalculateT1 and usp_CloseFiscalYear.
==============================================================================*/
USE CdnTaxPractice;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ARITHABORT ON;
GO

IF EXISTS (SELECT 1 FROM client.Client)
BEGIN
    PRINT '021 sample data already present - skipping.';
END
ELSE
BEGIN
    PRINT '021 seeding sample data...';

/*==============================================================================
  1. The practice
==============================================================================*/
INSERT INTO client.Practitioner (FullName, Designation, Email, IsPartner)
VALUES (N'Eleanor Vasquez',  N'CPA, CA',  N'eleanor.vasquez@example.ca',  1),
       (N'Desmond Achebe',   N'CPA, CGA', N'desmond.achebe@example.ca',   1),
       (N'Wei Zhang',        N'CPA',      N'wei.zhang@example.ca',        0),
       (N'Caitlin Murphy',   N'CPA',      N'caitlin.murphy@example.ca',   0),
       (N'Jonas Thibodeau',  NULL,        N'jonas.thibodeau@example.ca',  0);

/*==============================================================================
  2. Clients
==============================================================================*/
INSERT INTO client.Client
    (ClientCode, ClientType, FirstName, LastName, DateOfBirth, SIN, MaritalStatus,
     ProvinceCode, OnboardedDate, IsActive)
VALUES
    (N'IND-0001', 'I', N'Amelia',  N'Chen',      '1985-03-12', '123456782', N'Married',    'ON', '2019-02-11', 1),
    (N'IND-0002', 'I', N'Rajesh',  N'Patel',     '1978-11-05', '234567808', N'Married',    'BC', '2018-06-04', 1),
    (N'IND-0003', 'I', N'Marie',   N'Tremblay',  '1990-07-22', '345678023', N'Single',     'QC', '2020-01-15', 1),
    (N'IND-0004', 'I', N'Liam',    N'O''Connor', '1982-01-30', '456780246', N'Common-law', 'AB', '2017-09-18', 1),
    (N'IND-0005', 'I', N'Sofia',   N'Rossi',     '1995-05-09', '567802467', N'Single',     'ON', '2021-03-22', 1),
    (N'IND-0006', 'I', N'David',   N'Nakamura',  '1970-09-14', '678024688', N'Married',    'BC', '2016-11-07', 1),
    (N'IND-0007', 'I', N'Fatima',  N'Al-Hassan', '1988-12-03', '780246807', N'Married',    'ON', '2019-08-26', 1),
    (N'IND-0008', 'I', N'Owen',    N'Fraser',    '1975-04-18', '802468025', N'Divorced',   'AB', '2015-05-11', 1),
    (N'IND-0009', 'I', N'Priya',   N'Sharma',    '1992-02-27', '913579132', N'Single',     'ON', '2022-01-10', 1),
    (N'IND-0010', 'I', N'Nathan',  N'Boucher',   '1980-08-08', '135791358', N'Married',    'QC', '2018-04-16', 1),
    (N'IND-0011', 'I', N'Grace',   N'Kowalski',  '1968-06-21', '246802466', N'Widowed',    'ON', '2014-10-06', 1),
    (N'IND-0012', 'I', N'Tyler',   N'Beaulieu',  '1998-10-11', '357913573', N'Single',     'BC', '2023-02-13', 1),
    (N'IND-0013', 'I', N'Hannah',  N'Wong',      '1987-03-05', '468024682', N'Married',    'ON', '2017-07-24', 1),
    (N'IND-0014', 'I', N'Marcus',  N'Delaney',   '1973-12-19', '579135799', N'Married',    'NS', '2019-11-04', 1),
    (N'IND-0015', 'I', N'Ingrid',  N'Larsen',    '1991-09-30', '680246808', N'Single',     'MB', '2020-06-15', 1),
    (N'IND-0016', 'I', N'Samuel',  N'Okafor',    '1984-05-25', '791357916', N'Common-law', 'SK', '2021-09-20', 0);

INSERT INTO client.Client
    (ClientCode, ClientType, LegalName, IncorporationDate, BusinessNumber,
     FiscalYearEndMonth, ProvinceCode, OnboardedDate, IsActive)
VALUES
    (N'COR-0001', 'C', N'Northwind Consulting Ltd.',        '2012-04-01', '867530909', 12, 'ON', '2013-01-20', 1),
    (N'COR-0002', 'C', N'Pacific Rim Logistics Inc.',       '2015-09-15', '741258362',  6, 'BC', '2016-02-08', 1),
    (N'COR-0003', 'C', N'Prairie Sky Agritech Corp.',       '2018-01-08', '951753284', 12, 'AB', '2018-03-14', 1),
    (N'COR-0004', 'C', N'Maple Ridge Dental Prof. Corp.',   '2016-03-21', '159357466', 12, 'ON', '2016-05-30', 1),
    (N'COR-0005', 'C', N'Fleuve Saint-Laurent Media Inc.',  '2019-07-02', '357159268', 12, 'QC', '2019-09-09', 1),
    (N'COR-0006', 'C', N'Bayview Property Holdings Ltd.',   '2013-11-12', '753951821',  3, 'ON', '2014-01-27', 1),
    (N'COR-0007', 'C', N'Kootenay Craft Brewing Inc.',      '2020-05-19', '842695132', 12, 'BC', '2020-08-03', 1),
    (N'COR-0008', 'C', N'Athabasca Field Services Ltd.',    '2014-08-27', '192837466', 12, 'AB', '2015-04-13', 1),
    (N'COR-0009', 'C', N'Halifax Harbour Imports Inc.',     '2017-02-14', '564738292', 12, 'NS', '2017-06-19', 0);

/*==============================================================================
  3. Addresses and contacts
==============================================================================*/
INSERT INTO client.ClientAddress
    (ClientId, AddressType, Line1, Line2, City, ProvinceCode, PostalCode, IsPrimary)
SELECT c.ClientId,
       CASE WHEN c.ClientType = 'C' THEN N'RegisteredOffice' ELSE N'Mailing' END,
       a.Line1, a.Line2, a.City, c.ProvinceCode, a.PostalCode, 1
FROM   client.Client AS c
JOIN   (VALUES
    (N'IND-0001', N'418 Bathurst Street',        NULL,          N'Toronto',      'M5T 2S6'),
    (N'IND-0002', N'2255 West 12th Avenue',      N'Unit 4',     N'Vancouver',    'V6K 2N6'),
    (N'IND-0003', N'1240 rue Sainte-Catherine',  N'App. 812',   N'Montreal',     'H3G 1P8'),
    (N'IND-0004', N'7315 Elbow Drive SW',        NULL,          N'Calgary',      'T2V 1K2'),
    (N'IND-0005', N'88 Colborne Street',         N'Suite 300',  N'Toronto',      'M5E 1E7'),
    (N'IND-0006', N'3401 Cambie Street',         NULL,          N'Vancouver',    'V5Z 2W6'),
    (N'IND-0007', N'145 Bell Boulevard',         NULL,          N'Belleville',   'K8P 5R6'),
    (N'IND-0008', N'10230 Jasper Avenue',        N'Unit 1102',  N'Edmonton',     'T5J 4P6'),
    (N'IND-0009', N'62 Kingsway Crescent',       NULL,          N'Ottawa',       'K2P 1L4'),
    (N'IND-0010', N'505 boulevard Rene-Levesque',N'Bureau 210', N'Quebec',       'G1R 2B5'),
    (N'IND-0011', N'19 Trafalgar Road',          NULL,          N'Oakville',     'L6J 3G3'),
    (N'IND-0012', N'774 Yates Street',           N'Apt 6',      N'Victoria',     'V8W 1L8'),
    (N'IND-0013', N'2100 Bloor Street West',     NULL,          N'Toronto',      'M6S 1M7'),
    (N'IND-0014', N'1526 Barrington Street',     NULL,          N'Halifax',      'B3J 1Z1'),
    (N'IND-0015', N'333 Portage Avenue',         N'Suite 900',  N'Winnipeg',     'R3B 2C4'),
    (N'IND-0016', N'2405 Broad Street',          NULL,          N'Regina',       'S4P 1Y1'),
    (N'COR-0001', N'150 King Street West',       N'Suite 2100', N'Toronto',      'M5H 1J9'),
    (N'COR-0002', N'1055 West Hastings Street',  N'Floor 18',   N'Vancouver',    'V6E 2E9'),
    (N'COR-0003', N'400 3rd Avenue SW',          N'Suite 1500', N'Calgary',      'T2P 4H2'),
    (N'COR-0004', N'2800 Skymark Avenue',        N'Unit 12',    N'Mississauga',  'L4W 5A6'),
    (N'COR-0005', N'1155 rue University',        N'Bureau 700', N'Montreal',     'H3B 3A7'),
    (N'COR-0006', N'4711 Yonge Street',          N'Suite 1000', N'Toronto',      'M2N 6K8'),
    (N'COR-0007', N'625 Baker Street',           NULL,          N'Nelson',       'V1L 4H8'),
    (N'COR-0008', N'9945 108 Street NW',         N'Suite 400',  N'Edmonton',     'T5K 2G6'),
    (N'COR-0009', N'1801 Hollis Street',         N'Suite 1900', N'Halifax',      'B3J 3N4')
) AS a (ClientCode, Line1, Line2, City, PostalCode)
       ON a.ClientCode = c.ClientCode;

-- One primary email each, derived from the client code so it stays unique.
INSERT INTO client.ClientContact (ClientId, ContactType, ContactValue, IsPrimary)
SELECT c.ClientId, N'Email',
       LOWER(REPLACE(c.ClientCode, N'-', N'.')) + N'@example.ca', 1
FROM   client.Client AS c;

INSERT INTO client.ClientContact (ClientId, ContactType, ContactValue, IsPrimary)
SELECT c.ClientId, N'Phone',
       N'+1-416-555-' + RIGHT(N'0000' + CONVERT(NVARCHAR(4), 1000 + c.ClientId), 4), 1
FROM   client.Client AS c
WHERE  c.ClientType = 'C';

/*==============================================================================
  4. Engagements

  Individuals get a T1 engagement per year they have a return; corporations get
  T2 plus GST/HST and, for the ones the practice does books for, Bookkeeping.
==============================================================================*/
INSERT INTO client.Engagement
    (ClientId, TaxYear, ServiceType, PractitionerId, Status, FeeQuoted, FeeBilled,
     StartedOn, CompletedOn)
SELECT c.ClientId,
       y.TaxYear,
       N'T1',
       -- Spread clients across the three non-partner practitioners.
       3 + (c.ClientId % 3),
       CASE WHEN y.TaxYear < 2025 THEN N'Filed' ELSE N'InProgress' END,
       450.00 + (c.ClientId % 5) * 75.00,
       CASE WHEN y.TaxYear < 2025 THEN 450.00 + (c.ClientId % 5) * 75.00 END,
       DATEFROMPARTS(y.TaxYear + 1, 2, 15),
       CASE WHEN y.TaxYear < 2025 THEN DATEFROMPARTS(y.TaxYear + 1, 4, 20) END
FROM   client.Client AS c
CROSS  JOIN (VALUES (2023), (2024), (2025)) AS y (TaxYear)
WHERE  c.ClientType = 'I'
  AND  (c.ProvinceCode IN ('ON', 'BC', 'AB', 'QC') OR y.TaxYear = 2024);

INSERT INTO client.Engagement
    (ClientId, TaxYear, ServiceType, PractitionerId, Status, FeeQuoted, FeeBilled,
     StartedOn, CompletedOn)
SELECT c.ClientId, 2024, s.ServiceType,
       1 + (c.ClientId % 2),
       N'Filed',
       s.Fee, s.Fee,
       '2025-01-15', '2025-05-30'
FROM   client.Client AS c
CROSS  JOIN (VALUES (N'T2', 2400.00), (N'GSTHST', 900.00)) AS s (ServiceType, Fee)
WHERE  c.ClientType = 'C';

INSERT INTO client.Engagement
    (ClientId, TaxYear, ServiceType, PractitionerId, Status, FeeQuoted,
     StartedOn)
SELECT c.ClientId, 2024, N'Bookkeeping', 2, N'InProgress', 6000.00, '2024-01-02'
FROM   client.Client AS c
WHERE  c.ClientCode IN (N'COR-0001', N'COR-0004', N'COR-0007');

/*==============================================================================
  5. T1 returns

  Inserted as drafts, then transitioned to Filed/Assessed below - the status
  change is what gives tax.tr_T1Return_StatusHistory something to record.
==============================================================================*/
DECLARE @t1 TABLE
(
    ClientCode           NVARCHAR(20)   NOT NULL,
    TaxYear              SMALLINT       NOT NULL,
    EmploymentIncome     DECIMAL(19, 2) NOT NULL,
    InvestmentIncome     DECIMAL(19, 2) NOT NULL,
    SelfEmploymentIncome DECIMAL(19, 2) NOT NULL,
    PensionIncome        DECIMAL(19, 2) NOT NULL,
    OtherIncome          DECIMAL(19, 2) NOT NULL,
    RRSPDeduction        DECIMAL(19, 2) NOT NULL,
    UnionDues            DECIMAL(19, 2) NOT NULL,
    ChildCareExpenses    DECIMAL(19, 2) NOT NULL,
    TaxWithheld          DECIMAL(19, 2) NOT NULL,
    IsSelfEmployed       BIT            NOT NULL,
    PRIMARY KEY (ClientCode, TaxYear)
);

INSERT INTO @t1 VALUES
    -- code       yr    empl      invest  selfemp   pens   other   rrsp     union  childcare  withheld  se
    (N'IND-0001', 2023,  92000.00, 3200.00,     0.00,   0.00,   0.00,  9000.00, 1150.00,     0.00, 19500.00, 0),
    (N'IND-0001', 2024,  98500.00, 3850.00,     0.00,   0.00,   0.00, 10000.00, 1200.00,     0.00, 21400.00, 0),
    (N'IND-0001', 2025, 104000.00, 4100.00,     0.00,   0.00,   0.00, 11000.00, 1250.00,     0.00, 22900.00, 0),
    (N'IND-0002', 2023, 145000.00, 8600.00,     0.00,   0.00,   0.00, 18000.00,    0.00,  8000.00, 38000.00, 0),
    (N'IND-0002', 2024, 152000.00, 9400.00,     0.00,   0.00,   0.00, 19500.00,    0.00,  8500.00, 40100.00, 0),
    (N'IND-0002', 2025, 158000.00,10100.00,     0.00,   0.00,   0.00, 20000.00,    0.00,  9000.00, 41800.00, 0),
    (N'IND-0003', 2023,      0.00, 1200.00, 61000.00,   0.00,   0.00,  4000.00,    0.00,     0.00,     0.00, 1),
    (N'IND-0003', 2024,      0.00, 1500.00, 68000.00,   0.00,   0.00,  5000.00,    0.00,     0.00,     0.00, 1),
    (N'IND-0003', 2025,      0.00, 1750.00, 72500.00,   0.00,   0.00,  5500.00,    0.00,     0.00,     0.00, 1),
    (N'IND-0004', 2023, 118000.00,  600.00,     0.00,   0.00,   0.00, 14000.00,  980.00,  6000.00, 26500.00, 0),
    (N'IND-0004', 2024, 124000.00,  750.00,     0.00,   0.00,   0.00, 15000.00, 1010.00,  6200.00, 28100.00, 0),
    (N'IND-0004', 2025, 131000.00,  900.00,     0.00,   0.00,   0.00, 16000.00, 1050.00,  6400.00, 29800.00, 0),
    (N'IND-0005', 2023,  54000.00,  180.00,     0.00,   0.00, 1200.00,  2500.00,    0.00,     0.00,  8900.00, 0),
    (N'IND-0005', 2024,  58500.00,  240.00,     0.00,   0.00, 1400.00,  3000.00,    0.00,     0.00,  9800.00, 0),
    (N'IND-0005', 2025,  62000.00,  310.00,     0.00,   0.00, 1500.00,  3500.00,    0.00,     0.00, 10600.00, 0),
    (N'IND-0006', 2023,      0.00,24500.00,     0.00,58000.00,   0.00,     0.00,    0.00,     0.00, 14200.00, 0),
    (N'IND-0006', 2024,      0.00,26800.00,     0.00,60500.00,   0.00,     0.00,    0.00,     0.00, 15100.00, 0),
    (N'IND-0006', 2025,      0.00,28100.00,     0.00,62800.00,   0.00,     0.00,    0.00,     0.00, 15900.00, 0),
    (N'IND-0007', 2023, 210000.00,15400.00,     0.00,   0.00,   0.00, 30780.00,    0.00, 12000.00, 68000.00, 0),
    (N'IND-0007', 2024, 224000.00,17200.00,     0.00,   0.00,   0.00, 31560.00,    0.00, 12500.00, 72400.00, 0),
    (N'IND-0007', 2025, 238000.00,18900.00,     0.00,   0.00,   0.00, 32490.00,    0.00, 13000.00, 76900.00, 0),
    (N'IND-0008', 2023,  76000.00, 2100.00, 22000.00,   0.00,   0.00,  6000.00,  640.00,     0.00, 15800.00, 1),
    (N'IND-0008', 2024,  79000.00, 2400.00, 24500.00,   0.00,   0.00,  6500.00,  660.00,     0.00, 16600.00, 1),
    (N'IND-0008', 2025,  82000.00, 2700.00, 26000.00,   0.00,   0.00,  7000.00,  680.00,     0.00, 17400.00, 1),
    (N'IND-0009', 2023,  47000.00,   90.00,     0.00,   0.00,   0.00,  1800.00,    0.00,     0.00,  6900.00, 0),
    (N'IND-0009', 2024,  51000.00,  130.00,     0.00,   0.00,   0.00,  2200.00,    0.00,     0.00,  7800.00, 0),
    (N'IND-0009', 2025,  55500.00,  180.00,     0.00,   0.00,   0.00,  2600.00,    0.00,     0.00,  8800.00, 0),
    (N'IND-0010', 2023,  88000.00, 1900.00,     0.00,   0.00,   0.00,  8000.00,  890.00,  4500.00, 22100.00, 0),
    (N'IND-0010', 2024,  93000.00, 2200.00,     0.00,   0.00,   0.00,  8800.00,  910.00,  4700.00, 23600.00, 0),
    (N'IND-0010', 2025,  97500.00, 2500.00,     0.00,   0.00,   0.00,  9400.00,  930.00,  4900.00, 24900.00, 0),
    (N'IND-0011', 2023,      0.00,42000.00,     0.00,31000.00,   0.00,     0.00,    0.00,     0.00, 12800.00, 0),
    (N'IND-0011', 2024,      0.00,45500.00,     0.00,32400.00,   0.00,     0.00,    0.00,     0.00, 13700.00, 0),
    (N'IND-0011', 2025,      0.00,47800.00,     0.00,33800.00,   0.00,     0.00,    0.00,     0.00, 14400.00, 0),
    (N'IND-0012', 2023,  31000.00,    0.00,     0.00,   0.00, 2400.00,     0.00,    0.00,     0.00,  3100.00, 0),
    (N'IND-0012', 2024,  36000.00,   60.00,     0.00,   0.00, 2600.00,   900.00,    0.00,     0.00,  4200.00, 0),
    (N'IND-0012', 2025,  41000.00,  120.00,     0.00,   0.00, 2800.00,  1400.00,    0.00,     0.00,  5300.00, 0),
    (N'IND-0013', 2023, 134000.00, 6800.00,     0.00,   0.00,   0.00, 17000.00, 1340.00,  9000.00, 33200.00, 0),
    (N'IND-0013', 2024, 141000.00, 7500.00,     0.00,   0.00,   0.00, 18200.00, 1380.00,  9300.00, 35100.00, 0),
    (N'IND-0013', 2025, 148000.00, 8300.00,     0.00,   0.00,   0.00, 19000.00, 1420.00,  9600.00, 37000.00, 0),
    -- Provinces with 2024 brackets only
    (N'IND-0014', 2024, 108000.00, 4600.00,     0.00,   0.00,   0.00, 12000.00, 1080.00,     0.00, 26800.00, 0),
    (N'IND-0015', 2024,  67000.00,  820.00,     0.00,   0.00,   0.00,  4200.00,    0.00,  3100.00, 12400.00, 0),
    (N'IND-0016', 2024,      0.00,  400.00, 45000.00,   0.00,   0.00,  3000.00,    0.00,     0.00,     0.00, 1);

INSERT INTO tax.T1Return
    (ClientId, TaxYear, ProvinceOfResidence, FilingStatus, MaritalStatus, IsSelfEmployed,
     EmploymentIncome, InvestmentIncome, SelfEmploymentIncome, PensionIncome, OtherIncome,
     RRSPDeduction, UnionDues, ChildCareExpenses, TaxWithheld)
SELECT c.ClientId, t.TaxYear, c.ProvinceCode, N'Draft', c.MaritalStatus, t.IsSelfEmployed,
       t.EmploymentIncome, t.InvestmentIncome, t.SelfEmploymentIncome,
       t.PensionIncome, t.OtherIncome,
       t.RRSPDeduction, t.UnionDues, t.ChildCareExpenses, t.TaxWithheld
FROM   @t1          AS t
JOIN   client.Client AS c ON c.ClientCode = t.ClientCode;

/*==============================================================================
  6. Non-refundable credit claims

  The basic personal amount for every return, federally and (where the
  province has a seeded amount) provincially. The claim is capped at taxable
  income so a low earner cannot claim more than they made.
==============================================================================*/
INSERT INTO tax.CreditClaim (T1ReturnId, TaxYear, JurisdictionCode, CreditCode, ClaimedAmount)
SELECT r.T1ReturnId, r.TaxYear, 'CA', N'BPA',
       CASE WHEN r.TaxableIncome < nrc.MaxAmount THEN r.TaxableIncome ELSE nrc.MaxAmount END
FROM   tax.T1Return            AS r
JOIN   ref.NonRefundableCredit AS nrc
       ON nrc.TaxYear = r.TaxYear AND nrc.JurisdictionCode = 'CA' AND nrc.CreditCode = N'BPA';

INSERT INTO tax.CreditClaim (T1ReturnId, TaxYear, JurisdictionCode, CreditCode, ClaimedAmount)
SELECT r.T1ReturnId, r.TaxYear, r.ProvinceOfResidence, N'BPA',
       CASE WHEN r.TaxableIncome < nrc.MaxAmount THEN r.TaxableIncome ELSE nrc.MaxAmount END
FROM   tax.T1Return            AS r
JOIN   ref.NonRefundableCredit AS nrc
       ON  nrc.TaxYear          = r.TaxYear
       AND nrc.JurisdictionCode = r.ProvinceOfResidence
       AND nrc.CreditCode       = N'BPA';

-- The Canada employment amount, for returns with employment income.
INSERT INTO tax.CreditClaim (T1ReturnId, TaxYear, JurisdictionCode, CreditCode, ClaimedAmount)
SELECT r.T1ReturnId, r.TaxYear, 'CA', N'CEA',
       CASE WHEN r.EmploymentIncome < nrc.MaxAmount THEN r.EmploymentIncome ELSE nrc.MaxAmount END
FROM   tax.T1Return            AS r
JOIN   ref.NonRefundableCredit AS nrc
       ON nrc.TaxYear = r.TaxYear AND nrc.JurisdictionCode = 'CA' AND nrc.CreditCode = N'CEA'
WHERE  r.EmploymentIncome > 0;

/*==============================================================================
  7. Information slips

  Two paths on purpose: T4s are generated set-based from the returns, while
  two clients' investment slips arrive through tax.usp_ImportSlips as JSON, so
  the OPENJSON import path is exercised by loading the fixture.
==============================================================================*/
INSERT INTO tax.Slip
    (ClientId, TaxYear, SlipTypeCode, IssuerName, IssuerBusinessNumber,
     SlipReference, ReceivedDate)
SELECT r.ClientId, r.TaxYear, N'T4',
       N'Employer of ' + c.DisplayName,
       '867530909',
       CONCAT(N'T4-', r.TaxYear, N'-', r.ClientId),
       DATEFROMPARTS(r.TaxYear + 1, 2, 28)
FROM   tax.T1Return  AS r
JOIN   client.Client AS c ON c.ClientId = r.ClientId
WHERE  r.EmploymentIncome > 0;

INSERT INTO tax.SlipBox (SlipId, SlipTypeCode, BoxNumber, Amount)
SELECT s.SlipId, N'T4', b.BoxNumber, b.Amount
FROM   tax.Slip     AS s
JOIN   tax.T1Return AS r ON r.ClientId = s.ClientId AND r.TaxYear = s.TaxYear
CROSS  APPLY (VALUES
    (N'14', r.EmploymentIncome),
    (N'16', tax.fn_CPPContribution(r.TaxYear, r.EmploymentIncome)),
    (N'18', tax.fn_EIPremium(r.TaxYear, r.EmploymentIncome, r.ProvinceOfResidence)),
    (N'22', r.TaxWithheld),
    (N'44', r.UnionDues)
) AS b (BoxNumber, Amount)
WHERE  s.SlipTypeCode = N'T4'
  AND  b.Amount > 0;

-- T4A slips for the self-employed, carrying fees for services.
INSERT INTO tax.Slip
    (ClientId, TaxYear, SlipTypeCode, IssuerName, IssuerBusinessNumber,
     SlipReference, ReceivedDate)
SELECT r.ClientId, r.TaxYear, N'T4A',
       N'Contract payer', '741258362',
       CONCAT(N'T4A-', r.TaxYear, N'-', r.ClientId),
       DATEFROMPARTS(r.TaxYear + 1, 2, 28)
FROM   tax.T1Return AS r
WHERE  r.SelfEmploymentIncome > 0;

INSERT INTO tax.SlipBox (SlipId, SlipTypeCode, BoxNumber, Amount)
SELECT s.SlipId, N'T4A', N'048', r.SelfEmploymentIncome
FROM   tax.Slip     AS s
JOIN   tax.T1Return AS r ON r.ClientId = s.ClientId AND r.TaxYear = s.TaxYear
WHERE  s.SlipTypeCode = N'T4A';

-- Pension recipients get a T4A box 016.
INSERT INTO tax.Slip
    (ClientId, TaxYear, SlipTypeCode, IssuerName, SlipReference, ReceivedDate)
SELECT r.ClientId, r.TaxYear, N'T4A',
       N'Pension administrator',
       CONCAT(N'T4A-PEN-', r.TaxYear, N'-', r.ClientId),
       DATEFROMPARTS(r.TaxYear + 1, 2, 28)
FROM   tax.T1Return AS r
WHERE  r.PensionIncome > 0;

INSERT INTO tax.SlipBox (SlipId, SlipTypeCode, BoxNumber, Amount)
SELECT s.SlipId, N'T4A', b.BoxNumber, b.Amount
FROM   tax.Slip     AS s
JOIN   tax.T1Return AS r ON r.ClientId = s.ClientId AND r.TaxYear = s.TaxYear
CROSS  APPLY (VALUES
    (N'016', r.PensionIncome),
    (N'022', r.TaxWithheld)
) AS b (BoxNumber, Amount)
WHERE  s.SlipTypeCode = N'T4A'
  AND  s.SlipReference LIKE N'T4A-PEN-%'
  AND  b.Amount > 0;

/*--- the JSON import path -------------------------------------------------*/
DECLARE @clientId INT, @importJson NVARCHAR(MAX);

SELECT @clientId = ClientId FROM client.Client WHERE ClientCode = N'IND-0006';
SET @importJson = N'[
  {"slipType":"T5","issuer":"Dominion Trust Company","issuerBn":"951753284",
   "reference":"T5-2024-DT-01","receivedDate":"2025-02-20","amended":false,
   "boxes":[{"box":"13","amount":11200.00},
            {"box":"24","amount":9800.00},
            {"box":"25","amount":13524.00},
            {"box":"26","amount":2028.60}]},
  {"slipType":"T3","issuer":"Nakamura Family Trust","issuerBn":"159357466",
   "reference":"T3-2024-NF-01","receivedDate":"2025-03-14","amended":false,
   "boxes":[{"box":"21","amount":4300.00},
            {"box":"26","amount":1500.00}]}
]';
EXEC tax.usp_ImportSlips @ClientId = @clientId, @TaxYear = 2024, @SlipsJson = @importJson;

SELECT @clientId = ClientId FROM client.Client WHERE ClientCode = N'IND-0011';
SET @importJson = N'[
  {"slipType":"T5","issuer":"Bay Street Securities","issuerBn":"357159268",
   "reference":"T5-2024-BS-01","receivedDate":"2025-02-18","amended":false,
   "boxes":[{"box":"13","amount":18400.00},
            {"box":"24","amount":21000.00},
            {"box":"25","amount":28980.00},
            {"box":"26","amount":4347.00}]},
  {"slipType":"T5008","issuer":"Bay Street Securities","issuerBn":"357159268",
   "reference":"T5008-2024-BS-01","receivedDate":"2025-02-18","amended":false,
   "boxes":[{"box":"20","amount":62000.00},
            {"box":"21","amount":73500.00}]}
]';
EXEC tax.usp_ImportSlips @ClientId = @clientId, @TaxYear = 2024, @SlipsJson = @importJson;

/*==============================================================================
  8. RRSP contributions and instalments
==============================================================================*/
INSERT INTO tax.RRSPContribution
    (ClientId, TaxYear, ContributionDate, Amount, IsFirst60Days, IssuerName)
SELECT r.ClientId, r.TaxYear,
       DATEFROMPARTS(r.TaxYear, 11, 15),
       CONVERT(DECIMAL(19, 2), ROUND(r.RRSPDeduction * 0.7, 2)),
       0,
       N'Dominion Trust Company'
FROM   tax.T1Return AS r
WHERE  r.RRSPDeduction > 0
UNION ALL
-- The remainder contributed in the first 60 days of the following year.
SELECT r.ClientId, r.TaxYear,
       DATEFROMPARTS(r.TaxYear + 1, 2, 10),
       CONVERT(DECIMAL(19, 2), ROUND(r.RRSPDeduction * 0.3, 2)),
       1,
       N'Dominion Trust Company'
FROM   tax.T1Return AS r
WHERE  r.RRSPDeduction > 0;

-- Quarterly instalments for the self-employed, who have no tax withheld.
INSERT INTO tax.Installment (ClientId, TaxYear, DueDate, AmountDue, AmountPaid, PaidDate)
SELECT r.ClientId, r.TaxYear,
       DATEFROMPARTS(r.TaxYear, q.Month, 15),
       CONVERT(DECIMAL(19, 2), ROUND(r.SelfEmploymentIncome * 0.055, 2)),
       -- The last instalment of 2025 is still outstanding.
       CASE WHEN r.TaxYear = 2025 AND q.Month = 12 THEN 0
            ELSE CONVERT(DECIMAL(19, 2), ROUND(r.SelfEmploymentIncome * 0.055, 2)) END,
       CASE WHEN r.TaxYear = 2025 AND q.Month = 12 THEN NULL
            ELSE DATEFROMPARTS(r.TaxYear, q.Month, 15) END
FROM   tax.T1Return AS r
CROSS  JOIN (VALUES (3), (6), (9), (12)) AS q (Month)
WHERE  r.IsSelfEmployed = 1;

UPDATE r
SET    r.InstallmentsPaid = i.Paid
FROM   tax.T1Return AS r
JOIN   (SELECT ClientId, TaxYear, SUM(AmountPaid) AS Paid
        FROM   tax.Installment
        GROUP BY ClientId, TaxYear) AS i
       ON i.ClientId = r.ClientId AND i.TaxYear = r.TaxYear;

/*==============================================================================
  9. Corporate T2 returns
==============================================================================*/
INSERT INTO tax.T2Return
    (ClientId, FiscalYearStart, FiscalYearEnd, ProvinceOfOperation, FilingStatus,
     IsCCPC, GrossRevenue, TotalExpenses, SmallBusinessDeduction,
     FederalTax, ProvincialTax, InstallmentsPaid, FilingDueDate, DateFiled)
SELECT c.ClientId,
       DATEFROMPARTS(2024, 1, 1),
       DATEFROMPARTS(2024, 12, 31),
       c.ProvinceCode,
       N'Filed',
       1,
       t.GrossRevenue,
       t.TotalExpenses,
       -- Small business deduction on the first $500,000 of active income.
       CASE WHEN t.GrossRevenue - t.TotalExpenses > 500000.00 THEN 500000.00
            WHEN t.GrossRevenue - t.TotalExpenses > 0 THEN t.GrossRevenue - t.TotalExpenses
            ELSE 0 END,
       -- CCPC small business rate: 9% federally.
       CONVERT(DECIMAL(19, 2), ROUND(
           CASE WHEN t.GrossRevenue - t.TotalExpenses > 0
                THEN (t.GrossRevenue - t.TotalExpenses) * 0.09 ELSE 0 END, 2)),
       CONVERT(DECIMAL(19, 2), ROUND(
           CASE WHEN t.GrossRevenue - t.TotalExpenses > 0
                THEN (t.GrossRevenue - t.TotalExpenses) * 0.032 ELSE 0 END, 2)),
       t.InstallmentsPaid,
       '2025-06-30',
       '2025-06-12'
FROM   client.Client AS c
JOIN   (VALUES
    (N'COR-0001', 1850000.00, 1420000.00,  38000.00),
    (N'COR-0002', 4200000.00, 3910000.00,  24000.00),
    (N'COR-0003',  960000.00,  885000.00,   6000.00),
    (N'COR-0004', 1320000.00,  975000.00,  30000.00),
    (N'COR-0005',  610000.00,  588000.00,   1800.00),
    (N'COR-0006',  445000.00,  312000.00,  11000.00),
    (N'COR-0007',  780000.00,  742000.00,   3000.00),
    (N'COR-0008', 2650000.00, 2480000.00,  14000.00),
    (N'COR-0009',  330000.00,  349000.00,      0.00)
) AS t (ClientCode, GrossRevenue, TotalExpenses, InstallmentsPaid)
       ON t.ClientCode = c.ClientCode;

/*==============================================================================
  10. Books for the three bookkeeping clients

  Fiscal years, a chart of accounts, then twelve months of postings made
  through acct.usp_PostJournalEntry so the entries go in balanced and posted.
==============================================================================*/
INSERT INTO acct.FiscalYear (ClientId, StartDate, EndDate)
SELECT c.ClientId, DATEFROMPARTS(y.Yr, 1, 1), DATEFROMPARTS(y.Yr, 12, 31)
FROM   client.Client AS c
CROSS  JOIN (VALUES (2024), (2025)) AS y (Yr)
WHERE  c.ClientCode IN (N'COR-0001', N'COR-0004', N'COR-0007');

-- Control accounts first, so children can point at them.
INSERT INTO acct.Account
    (ClientId, AccountNumber, AccountName, AccountTypeCode, ParentAccountId, IsControlAccount)
SELECT c.ClientId, a.AccountNumber, a.AccountName, a.AccountTypeCode, NULL, 1
FROM   client.Client AS c
CROSS  JOIN (VALUES
    (N'1000', N'Assets',      N'Asset'),
    (N'2000', N'Liabilities', N'Liability'),
    (N'3000', N'Equity',      N'Equity'),
    (N'4000', N'Revenue',     N'Revenue'),
    (N'5000', N'Expenses',    N'Expense')
) AS a (AccountNumber, AccountName, AccountTypeCode)
WHERE  c.ClientCode IN (N'COR-0001', N'COR-0004', N'COR-0007');

INSERT INTO acct.Account
    (ClientId, AccountNumber, AccountName, AccountTypeCode, ParentAccountId, IsControlAccount)
SELECT c.ClientId, a.AccountNumber, a.AccountName, a.AccountTypeCode, parent.AccountId, 0
FROM   client.Client AS c
CROSS  JOIN (VALUES
    (N'1100', N'Cash',                     N'Asset',     N'1000'),
    (N'1200', N'Accounts Receivable',      N'Asset',     N'1000'),
    (N'1330', N'GST/HST Recoverable',      N'Asset',     N'1000'),
    (N'1500', N'Equipment',                N'Asset',     N'1000'),
    (N'2100', N'Accounts Payable',         N'Liability', N'2000'),
    (N'2310', N'GST/HST Payable',          N'Liability', N'2000'),
    (N'2400', N'Payroll Deductions Payable', N'Liability', N'2000'),
    (N'3100', N'Common Shares',            N'Equity',    N'3000'),
    (N'3200', N'Retained Earnings',        N'Equity',    N'3000'),
    (N'4100', N'Professional Fees',        N'Revenue',   N'4000'),
    (N'4200', N'Consulting Revenue',       N'Revenue',   N'4000'),
    (N'5100', N'Salaries and Wages',       N'Expense',   N'5000'),
    (N'5200', N'Rent',                     N'Expense',   N'5000'),
    (N'5300', N'Office Supplies',          N'Expense',   N'5000'),
    (N'5400', N'Professional Development', N'Expense',   N'5000'),
    (N'5500', N'Software Subscriptions',   N'Expense',   N'5000')
) AS a (AccountNumber, AccountName, AccountTypeCode, ParentNumber)
JOIN   acct.Account AS parent
       ON parent.ClientId = c.ClientId AND parent.AccountNumber = a.ParentNumber
WHERE  c.ClientCode IN (N'COR-0001', N'COR-0004', N'COR-0007');

/*--- opening balances and twelve months of activity -----------------------*/
DECLARE @books TABLE
(
    RowNo         INT IDENTITY (1, 1) PRIMARY KEY,
    ClientId      INT            NOT NULL,
    ClientCode    NVARCHAR(20)   NOT NULL,
    FiscalYearId  INT            NOT NULL,
    ProvinceCode  CHAR(2)        NOT NULL,
    MonthlyRevenue DECIMAL(19, 2) NOT NULL,
    MonthlyRent    DECIMAL(19, 2) NOT NULL,
    MonthlySalary  DECIMAL(19, 2) NOT NULL
);

INSERT INTO @books (ClientId, ClientCode, FiscalYearId, ProvinceCode,
                    MonthlyRevenue, MonthlyRent, MonthlySalary)
SELECT c.ClientId, c.ClientCode, fy.FiscalYearId, c.ProvinceCode,
       b.MonthlyRevenue, b.MonthlyRent, b.MonthlySalary
FROM   client.Client   AS c
JOIN   acct.FiscalYear AS fy ON fy.ClientId = c.ClientId AND YEAR(fy.EndDate) = 2024
JOIN   (VALUES
    (N'COR-0001', 118000.00, 9500.00, 62000.00),
    (N'COR-0004',  92000.00, 7200.00, 48000.00),
    (N'COR-0007',  54000.00, 4100.00, 26500.00)
) AS b (ClientCode, MonthlyRevenue, MonthlyRent, MonthlySalary)
       ON b.ClientCode = c.ClientCode;

DECLARE @lines        acct.JournalLineType;
DECLARE @rowNo        INT = 1,
        @maxRow       INT = (SELECT MAX(RowNo) FROM @books),
        @bkClientId   INT,
        @bkFiscalYear INT,
        @bkProvince   CHAR(2),
        @bkRevenue    DECIMAL(19, 2),
        @bkRent       DECIMAL(19, 2),
        @bkSalary     DECIMAL(19, 2),
        @month        INT,
        @entryDate    DATE,
        @rate         DECIMAL(9, 5),
        @rev          DECIMAL(19, 2),
        @gst          DECIMAL(19, 2),
        @rent         DECIMAL(19, 2),
        @itc          DECIMAL(19, 2),
        @salary       DECIMAL(19, 2),
        @withheld     DECIMAL(19, 2),
        @jeId         INT;

WHILE @rowNo <= @maxRow
BEGIN
    SELECT @bkClientId   = ClientId,
           @bkFiscalYear = FiscalYearId,
           @bkProvince   = ProvinceCode,
           @bkRevenue    = MonthlyRevenue,
           @bkRent       = MonthlyRent,
           @bkSalary     = MonthlySalary
    FROM   @books WHERE RowNo = @rowNo;

    -- Opening entry: share capital funding the bank account.
    DELETE FROM @lines;
    INSERT INTO @lines (LineNumber, AccountNumber, DebitAmount, CreditAmount, Memo)
    VALUES (1, N'1100', 250000.00,      0.00, N'Opening bank balance'),
           (2, N'1500',  85000.00,      0.00, N'Opening equipment at cost'),
           (3, N'3100',       0.00, 335000.00, N'Share capital');

    EXEC acct.usp_PostJournalEntry
         @ClientId       = @bkClientId,
         @FiscalYearId   = @bkFiscalYear,
         @EntryDate      = '2024-01-01',
         @Description    = N'Opening balances',
         @Lines          = @lines,
         @Source         = N'Manual',
         @PostedBy       = N'seed',
         @JournalEntryId = @jeId OUTPUT;

    SET @month = 1;
    WHILE @month <= 12
    BEGIN
        -- Amounts vary month to month but deterministically.
        SET @rev      = @bkRevenue + (@month * 1500.00);
        SET @rent     = @bkRent;
        SET @salary   = @bkSalary + (@month * 250.00);
        SET @rate     = ref.fn_GSTHSTRate(@bkProvince, DATEFROMPARTS(2024, @month, 15));
        SET @gst      = CONVERT(DECIMAL(19, 2), ROUND(@rev  * @rate, 2));
        SET @itc      = CONVERT(DECIMAL(19, 2), ROUND(@rent * @rate, 2));
        SET @withheld = CONVERT(DECIMAL(19, 2), ROUND(@salary * 0.28, 2));

        /*--- revenue billed -------------------------------------------*/
        SET @entryDate = DATEFROMPARTS(2024, @month, 15);
        DELETE FROM @lines;
        INSERT INTO @lines (LineNumber, AccountNumber, DebitAmount, CreditAmount, Memo)
        VALUES (1, N'1200', @rev + @gst, 0.00, N'Client billings'),
               (2, N'4100', 0.00, @rev,        N'Professional fees earned'),
               (3, N'2310', 0.00, @gst,        N'GST/HST collected');

        EXEC acct.usp_PostJournalEntry
             @ClientId       = @bkClientId,
             @FiscalYearId   = @bkFiscalYear,
             @EntryDate      = @entryDate,
             @Description    = N'Monthly billings',
             @Lines          = @lines,
             @Source         = N'Invoice',
             @PostedBy       = N'seed',
             @JournalEntryId = @jeId OUTPUT;

        /*--- rent and supplies paid -----------------------------------*/
        SET @entryDate = DATEFROMPARTS(2024, @month, 1);
        DELETE FROM @lines;
        INSERT INTO @lines (LineNumber, AccountNumber, DebitAmount, CreditAmount, Memo)
        VALUES (1, N'5200', @rent, 0.00,             N'Monthly rent'),
               (2, N'1330', @itc,  0.00,             N'Input tax credit on rent'),
               (3, N'1100', 0.00,  @rent + @itc,     N'Rent paid');

        EXEC acct.usp_PostJournalEntry
             @ClientId       = @bkClientId,
             @FiscalYearId   = @bkFiscalYear,
             @EntryDate      = @entryDate,
             @Description    = N'Rent and occupancy',
             @Lines          = @lines,
             @Source         = N'Manual',
             @PostedBy       = N'seed',
             @JournalEntryId = @jeId OUTPUT;

        /*--- payroll --------------------------------------------------*/
        SET @entryDate = DATEFROMPARTS(2024, @month, 28);
        DELETE FROM @lines;
        INSERT INTO @lines (LineNumber, AccountNumber, DebitAmount, CreditAmount, Memo)
        VALUES (1, N'5100', @salary, 0.00,               N'Gross salaries'),
               (2, N'2400', 0.00,    @withheld,          N'Source deductions withheld'),
               (3, N'1100', 0.00,    @salary - @withheld, N'Net pay disbursed');

        EXEC acct.usp_PostJournalEntry
             @ClientId       = @bkClientId,
             @FiscalYearId   = @bkFiscalYear,
             @EntryDate      = @entryDate,
             @Description    = N'Monthly payroll',
             @Lines          = @lines,
             @Source         = N'Payroll',
             @PostedBy       = N'seed',
             @JournalEntryId = @jeId OUTPUT;

        SET @month += 1;
    END

    SET @rowNo += 1;
END

/*==============================================================================
  11. The practice's own invoices to its clients

  Raised through acct.usp_GenerateInvoice so the sequence, the province lookup
  and the tax split are all exercised.
==============================================================================*/
DECLARE @invLines acct.InvoiceLineType;
DECLARE @invClientId  INT,
        @invId        INT,
        @invNo        INT = 1,
        @invMaxNo     INT,
        @invDate      DATE,
        @invFee       DECIMAL(19, 2),
        @invService   NVARCHAR(200),
        @invStatus    NVARCHAR(20);

DECLARE @invoiceQueue TABLE
(
    RowNo      INT IDENTITY (1, 1) PRIMARY KEY,
    ClientId   INT            NOT NULL,
    InvoiceDate DATE          NOT NULL,
    Fee        DECIMAL(19, 2) NOT NULL,
    Service    NVARCHAR(200)  NOT NULL,
    Status     NVARCHAR(20)   NOT NULL
);

-- One invoice per completed engagement, dated shortly after completion.
INSERT INTO @invoiceQueue (ClientId, InvoiceDate, Fee, Service, Status)
SELECT e.ClientId,
       DATEADD(DAY, 5, e.CompletedOn),
       e.FeeBilled,
       CONCAT(N'Preparation of ', e.ServiceType, N' return for ', e.TaxYear),
       -- Older invoices are settled; the 2024-year work is still outstanding.
       CASE WHEN e.TaxYear <= 2023 THEN N'Paid' ELSE N'Sent' END
FROM   client.Engagement AS e
WHERE  e.CompletedOn IS NOT NULL
  AND  e.FeeBilled  IS NOT NULL;

SELECT @invMaxNo = MAX(RowNo) FROM @invoiceQueue;

WHILE @invNo <= @invMaxNo
BEGIN
    SELECT @invClientId = ClientId,
           @invDate     = InvoiceDate,
           @invFee      = Fee,
           @invService  = Service,
           @invStatus   = Status
    FROM   @invoiceQueue WHERE RowNo = @invNo;

    DELETE FROM @invLines;
    INSERT INTO @invLines (LineNumber, Description, Quantity, UnitPrice, IsTaxable)
    VALUES (1, @invService, 1.00, @invFee, 1);

    -- A non-taxable disbursement recharge on every second invoice, so the
    -- fixture contains invoices where tax is charged on less than the subtotal.
    IF @invNo % 2 = 0
        INSERT INTO @invLines (LineNumber, Description, Quantity, UnitPrice, IsTaxable)
        VALUES (2, N'CRA filing disbursements (non-taxable)', 1.00, 45.00, 0);

    EXEC acct.usp_GenerateInvoice
         @ClientId    = @invClientId,
         @InvoiceDate = @invDate,
         @Lines       = @invLines,
         @PaymentTerms = 30,
         @Status      = @invStatus,
         @InvoiceId   = @invId OUTPUT;

    SET @invNo += 1;
END

-- Settle the invoices marked Paid, and part-settle a handful of the rest.
INSERT INTO acct.Payment (InvoiceId, PaymentDate, Amount, Method, Reference)
SELECT i.InvoiceId,
       DATEADD(DAY, 21, i.InvoiceDate),
       i.Total,
       N'EFT',
       CONCAT(N'EFT-', i.InvoiceNumber)
FROM   acct.Invoice AS i
WHERE  i.Status = N'Paid';

INSERT INTO acct.Payment (InvoiceId, PaymentDate, Amount, Method, Reference)
SELECT i.InvoiceId,
       DATEADD(DAY, 25, i.InvoiceDate),
       CONVERT(DECIMAL(19, 2), ROUND(i.Total * 0.5, 2)),
       N'Cheque',
       CONCAT(N'CHQ-', i.InvoiceNumber)
FROM   acct.Invoice AS i
WHERE  i.Status = N'Sent'
  AND  i.InvoiceNumber % 5 = 0;

UPDATE i
SET    i.Status = N'PartiallyPaid'
FROM   acct.Invoice AS i
WHERE  i.Status = N'Sent'
  AND  EXISTS (SELECT 1 FROM acct.Payment AS p WHERE p.InvoiceId = i.InvoiceId);

/*==============================================================================
  12. GST/HST returns

  Filed quarterly for 2024 from the books posted above.
==============================================================================*/
DECLARE @gstClientId INT,
        @gstReturnId INT,
        @q           INT,
        @gstStart    DATE,
        @gstEnd      DATE;

DECLARE gst_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT c.ClientId
    FROM   client.Client AS c
    WHERE  c.ClientCode IN (N'COR-0001', N'COR-0004', N'COR-0007');

OPEN gst_cursor;
FETCH NEXT FROM gst_cursor INTO @gstClientId;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @q = 1;
    WHILE @q <= 4
    BEGIN
        -- Calendar quarters of 2024.
        SET @gstStart = DATEFROMPARTS(2024, (@q - 1) * 3 + 1, 1);
        SET @gstEnd   = EOMONTH(DATEFROMPARTS(2024, @q * 3, 1));

        EXEC tax.usp_FileGSTHSTReturn
             @ClientId       = @gstClientId,
             @PeriodStart    = @gstStart,
             @PeriodEnd      = @gstEnd,
             @FrequencyCode  = N'Quarterly',
             @GSTHSTReturnId = @gstReturnId OUTPUT;

        SET @q += 1;
    END
    FETCH NEXT FROM gst_cursor INTO @gstClientId;
END

CLOSE gst_cursor;
DEALLOCATE gst_cursor;

/*==============================================================================
  13. Payroll
==============================================================================*/
INSERT INTO payroll.Employee
    (EmployerClientId, EmployeeNumber, FirstName, LastName, SIN,
     ProvinceOfEmployment, HireDate, PayFrequency, AnnualSalary,
     TD1FederalAmount, TD1ProvincialAmount)
SELECT c.ClientId, e.EmployeeNumber, e.FirstName, e.LastName, e.SIN,
       c.ProvinceCode, e.HireDate, e.PayFrequency, e.AnnualSalary,
       15705.00,
       CASE c.ProvinceCode WHEN 'ON' THEN 12399.00 WHEN 'BC' THEN 12580.00
                           WHEN 'AB' THEN 21885.00 ELSE 15705.00 END
FROM   client.Client AS c
JOIN   (VALUES
    (N'COR-0001', N'E-101', N'Aisha',   N'Bello',      '102030400', '2019-03-04', N'BiWeekly',  96000.00),
    (N'COR-0001', N'E-102', N'Gordon',  N'MacLeod',    '203040506', '2020-07-13', N'BiWeekly',  82000.00),
    (N'COR-0001', N'E-103', N'Yuki',    N'Tanaka',     '304050602', '2021-01-11', N'BiWeekly',  74500.00),
    (N'COR-0001', N'E-104', N'Peter',   N'Novak',      '405060708', '2022-05-02', N'BiWeekly',  68000.00),
    (N'COR-0001', N'E-105', N'Renee',   N'Charbonneau','506070804', '2023-09-18', N'BiWeekly',  61000.00),
    (N'COR-0004', N'E-201', N'Devon',   N'Whitfield',  '112233440', '2018-02-20', N'Monthly',  118000.00),
    (N'COR-0004', N'E-202', N'Salma',   N'Haddad',     '223344557', '2020-11-09', N'Monthly',   88000.00),
    (N'COR-0004', N'E-203', N'Colin',   N'Beaumont',   '334455664', '2021-06-14', N'Monthly',   72000.00),
    (N'COR-0004', N'E-204', N'Nadia',   N'Petrov',     '445566771', '2022-08-29', N'Monthly',   64000.00),
    (N'COR-0004', N'E-205', N'Thomas',  N'Gagnon',     '556677888', '2023-04-03', N'Monthly',   57000.00)
) AS e (ClientCode, EmployeeNumber, FirstName, LastName, SIN, HireDate,
        PayFrequency, AnnualSalary)
       ON e.ClientCode = c.ClientCode;

-- 26 biweekly periods for COR-0001, 12 monthly periods for COR-0004.
INSERT INTO payroll.PayPeriod (ClientId, TaxYear, PeriodNumber, StartDate, EndDate, PayDate)
SELECT c.ClientId, 2024, n.N,
       DATEADD(DAY, (n.N - 1) * 14, '2024-01-01'),
       DATEADD(DAY, (n.N - 1) * 14 + 13, '2024-01-01'),
       DATEADD(DAY, (n.N - 1) * 14 + 18, '2024-01-01')
FROM   client.Client AS c
CROSS  JOIN (SELECT TOP (26) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
             FROM sys.all_objects) AS n
WHERE  c.ClientCode = N'COR-0001';

INSERT INTO payroll.PayPeriod (ClientId, TaxYear, PeriodNumber, StartDate, EndDate, PayDate)
SELECT c.ClientId, 2024, n.N,
       DATEFROMPARTS(2024, n.N, 1),
       EOMONTH(DATEFROMPARTS(2024, n.N, 1)),
       DATEADD(DAY, 3, EOMONTH(DATEFROMPARTS(2024, n.N, 1)))
FROM   client.Client AS c
CROSS  JOIN (SELECT TOP (12) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
             FROM sys.all_objects) AS n
WHERE  c.ClientCode = N'COR-0004';

DECLARE @ppClientId INT, @ppId INT;
DECLARE payroll_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT pp.ClientId, pp.PayPeriodId
    FROM   payroll.PayPeriod AS pp
    ORDER  BY pp.ClientId, pp.PeriodNumber;   -- order matters: YTD is cumulative

OPEN payroll_cursor;
FETCH NEXT FROM payroll_cursor INTO @ppClientId, @ppId;

WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC payroll.usp_RunPayroll @ClientId = @ppClientId, @PayPeriodId = @ppId;
    FETCH NEXT FROM payroll_cursor INTO @ppClientId, @ppId;
END

CLOSE payroll_cursor;
DEALLOCATE payroll_cursor;

/*==============================================================================
  14. Calculate the returns, then move them through their filing statuses
==============================================================================*/
EXEC tax.usp_RecalculateAllReturns @TaxYear = 2023;
EXEC tax.usp_RecalculateAllReturns @TaxYear = 2024;
EXEC tax.usp_RecalculateAllReturns @TaxYear = 2025;

-- Draft -> Filed -> Assessed. Each UPDATE fires tax.tr_T1Return_StatusHistory,
-- so audit.ReturnStatusHistory ends up with a real transition trail.
UPDATE tax.T1Return
SET    FilingStatus = N'Filed',
       DateFiled    = DATEFROMPARTS(TaxYear + 1, 4, 22)
WHERE  TaxYear <= 2024;

UPDATE tax.T1Return
SET    FilingStatus         = N'Assessed',
       AssessedAt           = DATEADD(DAY, 35, CONVERT(DATETIME2(3), DateFiled)),
       NoticeOfAssessmentNo = CONCAT(N'NOA-', TaxYear, N'-', RIGHT(N'000000' + CONVERT(NVARCHAR(6), T1ReturnId), 6))
WHERE  TaxYear = 2023;

/*==============================================================================
  15. Close one fiscal year, so the schema ships with a closed period
==============================================================================*/
DECLARE @closeClientId INT, @closeFiscalYearId INT;

SELECT @closeClientId     = c.ClientId,
       @closeFiscalYearId = fy.FiscalYearId
FROM   client.Client   AS c
JOIN   acct.FiscalYear AS fy ON fy.ClientId = c.ClientId AND YEAR(fy.EndDate) = 2024
WHERE  c.ClientCode = N'COR-0007';

EXEC acct.usp_CloseFiscalYear
     @ClientId     = @closeClientId,
     @FiscalYearId = @closeFiscalYearId,
     @PostedBy     = N'seed';

/*==============================================================================
  16. Lock the 2023 tax year

  Done last, after 2023's returns have been calculated. From here on
  tax.usp_CalculateT1 rejects them with error 50011, which is the condition
  099_verify.sql asserts against.
==============================================================================*/
UPDATE ref.TaxYear SET IsLocked = 1 WHERE TaxYear = 2023;

PRINT '021 sample data seeded.';

END
GO
