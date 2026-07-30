/*==============================================================================
  020 - Reference data seed  (PostgreSQL)

  Port of db/sqlserver/020_seed_reference_data.sql.

  ---------------------------------------------------------------------------
  ACCURACY NOTICE

  The rates, brackets and thresholds below are drawn from CRA and provincial
  published figures for 2023-2025 and are here to make the calculations behave
  realistically under test. They are FIXTURE DATA, not a tax engine. Do not
  rely on any figure here for an actual filing.
  ---------------------------------------------------------------------------

  Every statement is a MERGE, exactly as in the SQL Server original, so the file
  is re-runnable and converges on the same state. PostgreSQL 15+ implements
  MERGE; the only dialect differences are MERGE INTO rather than MERGE, and
  WHEN NOT MATCHED rather than WHEN NOT MATCHED BY TARGET.

  This is the construct AWS SCT could not translate at all (action item 9996,
  "Transformer error occurred in mergeStatement") - it is supported here.

  Date literals are written DATE 'yyyy-mm-dd': PostgreSQL types a bare quoted
  date inside a VALUES list as text, which then fails to compare against a date
  column.
==============================================================================*/

SET client_min_messages = warning;
/*==============================================================================
  Provinces and territories
==============================================================================*/
MERGE INTO ref.province AS tgt
USING (VALUES
    ('AB', 'Alberta',                   0,  1),
    ('BC', 'British Columbia',          0,  2),
    ('MB', 'Manitoba',                  0,  3),
    ('NB', 'New Brunswick',             0,  4),
    ('NL', 'Newfoundland and Labrador', 0,  5),
    ('NS', 'Nova Scotia',               0,  6),
    ('NT', 'Northwest Territories',     1,  7),
    ('NU', 'Nunavut',                   1,  8),
    ('ON', 'Ontario',                   0,  9),
    ('PE', 'Prince Edward Island',      0, 10),
    ('QC', 'Quebec',                    0, 11),
    ('SK', 'Saskatchewan',              0, 12),
    ('YT', 'Yukon',                     1, 13)
) AS src (ProvinceCode, ProvinceName, IsTerritory, SortOrder)
    ON tgt.ProvinceCode = src.ProvinceCode
WHEN MATCHED THEN
    UPDATE SET ProvinceName = src.ProvinceName,
               IsTerritory  = src.IsTerritory,
               SortOrder    = src.SortOrder
WHEN NOT MATCHED THEN
    INSERT (ProvinceCode, ProvinceName, IsTerritory, SortOrder)
    VALUES (src.ProvinceCode, src.ProvinceName, src.IsTerritory, src.SortOrder);

/*==============================================================================
  Jurisdictions: the federal government plus one per province
==============================================================================*/
MERGE INTO ref.jurisdiction AS tgt
USING (
    SELECT 'CA' AS JurisdictionCode, 'Canada (federal)' AS JurisdictionName,
           1 AS IsFederal, NULL::char(2) AS ProvinceCode
    UNION ALL
    SELECT p.ProvinceCode, p.ProvinceName, 0, p.ProvinceCode
    FROM   ref.Province AS p
) AS src
    ON tgt.JurisdictionCode = src.JurisdictionCode
WHEN MATCHED THEN
    UPDATE SET JurisdictionName = src.JurisdictionName,
               IsFederal        = src.IsFederal,
               ProvinceCode     = src.ProvinceCode
WHEN NOT MATCHED THEN
    INSERT (JurisdictionCode, JurisdictionName, IsFederal, ProvinceCode)
    VALUES (src.JurisdictionCode, src.JurisdictionName, src.IsFederal, src.ProvinceCode);

/*==============================================================================
  Sales tax rates

  HST provinces charge a single blended rate; the rest charge 5% GST with an
  optional provincial tax on top. Nova Scotia's reduction from 15% to 14% on
  2025-04-01 is seeded as two date ranges, which is the whole reason
  ref.SalesTaxRate is a range table.
==============================================================================*/
MERGE INTO ref.salestaxrate AS tgt
USING (VALUES
    --  prov  from          to             GST      HST      PST      QST
    ('AB', DATE '2023-01-01', NULL::date, 0.05000, 0.00000, 0.00000, 0.00000),
    ('BC', DATE '2023-01-01', NULL::date, 0.05000, 0.00000, 0.07000, 0.00000),
    ('MB', DATE '2023-01-01', NULL::date, 0.05000, 0.00000, 0.07000, 0.00000),
    ('NB', DATE '2023-01-01', NULL::date, 0.00000, 0.15000, 0.00000, 0.00000),
    ('NL', DATE '2023-01-01', NULL::date, 0.00000, 0.15000, 0.00000, 0.00000),
    ('NS', DATE '2023-01-01', DATE '2025-04-01', 0.00000, 0.15000, 0.00000, 0.00000),
    ('NS', DATE '2025-04-01', NULL::date, 0.00000, 0.14000, 0.00000, 0.00000),
    ('NT', DATE '2023-01-01', NULL::date, 0.05000, 0.00000, 0.00000, 0.00000),
    ('NU', DATE '2023-01-01', NULL::date, 0.05000, 0.00000, 0.00000, 0.00000),
    ('ON', DATE '2023-01-01', NULL::date, 0.00000, 0.13000, 0.00000, 0.00000),
    ('PE', DATE '2023-01-01', NULL::date, 0.00000, 0.15000, 0.00000, 0.00000),
    ('QC', DATE '2023-01-01', NULL::date, 0.05000, 0.00000, 0.00000, 0.09975),
    ('SK', DATE '2023-01-01', NULL::date, 0.05000, 0.00000, 0.06000, 0.00000),
    ('YT', DATE '2023-01-01', NULL::date, 0.05000, 0.00000, 0.00000, 0.00000)
) AS src (ProvinceCode, EffectiveFrom, EffectiveTo, GSTRate, HSTRate, PSTRate, QSTRate)
    ON  tgt.ProvinceCode  = src.ProvinceCode
    AND tgt.EffectiveFrom = src.EffectiveFrom
WHEN MATCHED THEN
    UPDATE SET EffectiveTo = src.EffectiveTo,
               GSTRate     = src.GSTRate,
               HSTRate     = src.HSTRate,
               PSTRate     = src.PSTRate,
               QSTRate     = src.QSTRate
WHEN NOT MATCHED THEN
    INSERT (ProvinceCode, EffectiveFrom, EffectiveTo, GSTRate, HSTRate, PSTRate, QSTRate)
    VALUES (src.ProvinceCode, src.EffectiveFrom, src.EffectiveTo,
            src.GSTRate, src.HSTRate, src.PSTRate, src.QSTRate);

/*==============================================================================
  Tax years

  Deadlines that fall on a weekend move to the next business day, which is why
  the self-employment and RRSP dates below are not always June 15 / March 1.
  2023 is left unlocked here and locked at the end of 021, after its returns
  have been calculated.
==============================================================================*/
MERGE INTO ref.taxyear AS tgt
USING (VALUES
    (2023, DATE '2024-04-30', DATE '2024-06-17', DATE '2024-02-29', 3000.00),
    (2024, DATE '2025-04-30', DATE '2025-06-16', DATE '2025-03-03', 3000.00),
    (2025, DATE '2026-04-30', DATE '2026-06-15', DATE '2026-03-02', 3000.00)
) AS src (TaxYear, T1FilingDeadline, SelfEmployedDeadline, RRSPDeadline, InstallmentThreshold)
    ON tgt.TaxYear = src.TaxYear
WHEN MATCHED THEN
    UPDATE SET T1FilingDeadline     = src.T1FilingDeadline,
               SelfEmployedDeadline = src.SelfEmployedDeadline,
               RRSPDeadline         = src.RRSPDeadline,
               InstallmentThreshold = src.InstallmentThreshold
WHEN NOT MATCHED THEN
    INSERT (TaxYear, T1FilingDeadline, SelfEmployedDeadline, RRSPDeadline, InstallmentThreshold)
    VALUES (src.TaxYear, src.T1FilingDeadline, src.SelfEmployedDeadline,
            src.RRSPDeadline, src.InstallmentThreshold);

/*==============================================================================
  Tax brackets

  A NULL UpperBound marks the top bracket. The federal 2025 lowest rate is
  seeded as 14.5%: the statutory rate dropped from 15% to 14% part-way through
  2025, and 14.5% is the full-year effective rate that results.
==============================================================================*/
MERGE INTO ref.taxbracket AS tgt
USING (VALUES
    /*---------------------------- FEDERAL ---------------------------------*/
    (2023, 'CA', 1,       0.00, 53359.00::numeric(19,2), 0.150000),
    (2023, 'CA', 2,   53359.00, 106717.00::numeric(19,2), 0.205000),
    (2023, 'CA', 3,  106717.00, 165430.00::numeric(19,2), 0.260000),
    (2023, 'CA', 4,  165430.00, 235675.00::numeric(19,2), 0.290000),
    (2023, 'CA', 5,  235675.00, NULL::numeric(19,2), 0.330000),

    (2024, 'CA', 1,       0.00, 55867.00::numeric(19,2), 0.150000),
    (2024, 'CA', 2,   55867.00, 111733.00::numeric(19,2), 0.205000),
    (2024, 'CA', 3,  111733.00, 173205.00::numeric(19,2), 0.260000),
    (2024, 'CA', 4,  173205.00, 246752.00::numeric(19,2), 0.290000),
    (2024, 'CA', 5,  246752.00, NULL::numeric(19,2), 0.330000),

    (2025, 'CA', 1,       0.00, 57375.00::numeric(19,2), 0.145000),
    (2025, 'CA', 2,   57375.00, 114750.00::numeric(19,2), 0.205000),
    (2025, 'CA', 3,  114750.00, 177882.00::numeric(19,2), 0.260000),
    (2025, 'CA', 4,  177882.00, 253414.00::numeric(19,2), 0.290000),
    (2025, 'CA', 5,  253414.00, NULL::numeric(19,2), 0.330000),

    /*---------------------------- ONTARIO ---------------------------------*/
    (2023, 'ON', 1,       0.00, 49231.00::numeric(19,2), 0.050500),
    (2023, 'ON', 2,   49231.00, 98463.00::numeric(19,2), 0.091500),
    (2023, 'ON', 3,   98463.00, 150000.00::numeric(19,2), 0.111600),
    (2023, 'ON', 4,  150000.00, 220000.00::numeric(19,2), 0.121600),
    (2023, 'ON', 5,  220000.00, NULL::numeric(19,2), 0.131600),

    (2024, 'ON', 1,       0.00, 51446.00::numeric(19,2), 0.050500),
    (2024, 'ON', 2,   51446.00, 102894.00::numeric(19,2), 0.091500),
    (2024, 'ON', 3,  102894.00, 150000.00::numeric(19,2), 0.111600),
    (2024, 'ON', 4,  150000.00, 220000.00::numeric(19,2), 0.121600),
    (2024, 'ON', 5,  220000.00, NULL::numeric(19,2), 0.131600),

    (2025, 'ON', 1,       0.00, 52886.00::numeric(19,2), 0.050500),
    (2025, 'ON', 2,   52886.00, 105775.00::numeric(19,2), 0.091500),
    (2025, 'ON', 3,  105775.00, 150000.00::numeric(19,2), 0.111600),
    (2025, 'ON', 4,  150000.00, 220000.00::numeric(19,2), 0.121600),
    (2025, 'ON', 5,  220000.00, NULL::numeric(19,2), 0.131600),

    /*------------------------ BRITISH COLUMBIA ----------------------------*/
    (2023, 'BC', 1,       0.00, 45654.00::numeric(19,2), 0.050600),
    (2023, 'BC', 2,   45654.00, 91310.00::numeric(19,2), 0.077000),
    (2023, 'BC', 3,   91310.00, 104835.00::numeric(19,2), 0.105000),
    (2023, 'BC', 4,  104835.00, 127299.00::numeric(19,2), 0.122900),
    (2023, 'BC', 5,  127299.00, 172602.00::numeric(19,2), 0.147000),
    (2023, 'BC', 6,  172602.00, 240716.00::numeric(19,2), 0.168000),
    (2023, 'BC', 7,  240716.00, NULL::numeric(19,2), 0.205000),

    (2024, 'BC', 1,       0.00, 47937.00::numeric(19,2), 0.050600),
    (2024, 'BC', 2,   47937.00, 95875.00::numeric(19,2), 0.077000),
    (2024, 'BC', 3,   95875.00, 110076.00::numeric(19,2), 0.105000),
    (2024, 'BC', 4,  110076.00, 133664.00::numeric(19,2), 0.122900),
    (2024, 'BC', 5,  133664.00, 181232.00::numeric(19,2), 0.147000),
    (2024, 'BC', 6,  181232.00, 252752.00::numeric(19,2), 0.168000),
    (2024, 'BC', 7,  252752.00, NULL::numeric(19,2), 0.205000),

    (2025, 'BC', 1,       0.00, 49279.00::numeric(19,2), 0.050600),
    (2025, 'BC', 2,   49279.00, 98560.00::numeric(19,2), 0.077000),
    (2025, 'BC', 3,   98560.00, 113158.00::numeric(19,2), 0.105000),
    (2025, 'BC', 4,  113158.00, 137407.00::numeric(19,2), 0.122900),
    (2025, 'BC', 5,  137407.00, 186306.00::numeric(19,2), 0.147000),
    (2025, 'BC', 6,  186306.00, 259829.00::numeric(19,2), 0.168000),
    (2025, 'BC', 7,  259829.00, NULL::numeric(19,2), 0.205000),

    /*---------------------------- ALBERTA ---------------------------------*/
    (2023, 'AB', 1,       0.00, 142292.00::numeric(19,2), 0.100000),
    (2023, 'AB', 2,  142292.00, 170751.00::numeric(19,2), 0.120000),
    (2023, 'AB', 3,  170751.00, 227668.00::numeric(19,2), 0.130000),
    (2023, 'AB', 4,  227668.00, 341502.00::numeric(19,2), 0.140000),
    (2023, 'AB', 5,  341502.00, NULL::numeric(19,2), 0.150000),

    (2024, 'AB', 1,       0.00, 148269.00::numeric(19,2), 0.100000),
    (2024, 'AB', 2,  148269.00, 177922.00::numeric(19,2), 0.120000),
    (2024, 'AB', 3,  177922.00, 237230.00::numeric(19,2), 0.130000),
    (2024, 'AB', 4,  237230.00, 355845.00::numeric(19,2), 0.140000),
    (2024, 'AB', 5,  355845.00, NULL::numeric(19,2), 0.150000),

    -- Alberta added a new 8% first bracket in 2025.
    (2025, 'AB', 1,       0.00, 60000.00::numeric(19,2), 0.080000),
    (2025, 'AB', 2,   60000.00, 151234.00::numeric(19,2), 0.100000),
    (2025, 'AB', 3,  151234.00, 181481.00::numeric(19,2), 0.120000),
    (2025, 'AB', 4,  181481.00, 241974.00::numeric(19,2), 0.130000),
    (2025, 'AB', 5,  241974.00, 362961.00::numeric(19,2), 0.140000),
    (2025, 'AB', 6,  362961.00, NULL::numeric(19,2), 0.150000),

    /*----------------------------- QUEBEC ---------------------------------*/
    (2023, 'QC', 1,       0.00, 49275.00::numeric(19,2), 0.140000),
    (2023, 'QC', 2,   49275.00, 98540.00::numeric(19,2), 0.190000),
    (2023, 'QC', 3,   98540.00, 119910.00::numeric(19,2), 0.240000),
    (2023, 'QC', 4,  119910.00, NULL::numeric(19,2), 0.257500),

    (2024, 'QC', 1,       0.00, 51780.00::numeric(19,2), 0.140000),
    (2024, 'QC', 2,   51780.00, 103545.00::numeric(19,2), 0.190000),
    (2024, 'QC', 3,  103545.00, 126000.00::numeric(19,2), 0.240000),
    (2024, 'QC', 4,  126000.00, NULL::numeric(19,2), 0.257500),

    (2025, 'QC', 1,       0.00, 53255.00::numeric(19,2), 0.140000),
    (2025, 'QC', 2,   53255.00, 106495.00::numeric(19,2), 0.190000),
    (2025, 'QC', 3,  106495.00, 129590.00::numeric(19,2), 0.240000),
    (2025, 'QC', 4,  129590.00, NULL::numeric(19,2), 0.257500),

    /*----------------- REMAINING PROVINCES - 2024 ONLY --------------------*/
    (2024, 'MB', 1,       0.00, 47000.00::numeric(19,2), 0.108000),
    (2024, 'MB', 2,   47000.00, 100000.00::numeric(19,2), 0.127500),
    (2024, 'MB', 3,  100000.00, NULL::numeric(19,2), 0.174000),

    (2024, 'SK', 1,       0.00, 52057.00::numeric(19,2), 0.105000),
    (2024, 'SK', 2,   52057.00, 148734.00::numeric(19,2), 0.125000),
    (2024, 'SK', 3,  148734.00, NULL::numeric(19,2), 0.145000),

    (2024, 'NS', 1,       0.00, 29590.00::numeric(19,2), 0.087900),
    (2024, 'NS', 2,   29590.00, 59180.00::numeric(19,2), 0.149500),
    (2024, 'NS', 3,   59180.00, 93000.00::numeric(19,2), 0.166700),
    (2024, 'NS', 4,   93000.00, 150000.00::numeric(19,2), 0.175000),
    (2024, 'NS', 5,  150000.00, NULL::numeric(19,2), 0.210000),

    (2024, 'NB', 1,       0.00, 49958.00::numeric(19,2), 0.094000),
    (2024, 'NB', 2,   49958.00, 99916.00::numeric(19,2), 0.140000),
    (2024, 'NB', 3,   99916.00, 185064.00::numeric(19,2), 0.160000),
    (2024, 'NB', 4,  185064.00, NULL::numeric(19,2), 0.195000),

    (2024, 'NL', 1,       0.00, 43198.00::numeric(19,2), 0.087000),
    (2024, 'NL', 2,   43198.00, 86395.00::numeric(19,2), 0.145000),
    (2024, 'NL', 3,   86395.00, 154244.00::numeric(19,2), 0.158000),
    (2024, 'NL', 4,  154244.00, 215943.00::numeric(19,2), 0.178000),
    (2024, 'NL', 5,  215943.00, 275870.00::numeric(19,2), 0.198000),
    (2024, 'NL', 6,  275870.00, 551739.00::numeric(19,2), 0.208000),
    (2024, 'NL', 7,  551739.00, 1103478.00::numeric(19,2), 0.213000),
    (2024, 'NL', 8, 1103478.00, NULL::numeric(19,2), 0.218000),

    (2024, 'PE', 1,       0.00, 32656.00::numeric(19,2), 0.096500),
    (2024, 'PE', 2,   32656.00, 64313.00::numeric(19,2), 0.136300),
    (2024, 'PE', 3,   64313.00, 105000.00::numeric(19,2), 0.166500),
    (2024, 'PE', 4,  105000.00, 140000.00::numeric(19,2), 0.180000),
    (2024, 'PE', 5,  140000.00, NULL::numeric(19,2), 0.187500),

    (2024, 'NT', 1,       0.00, 50597.00::numeric(19,2), 0.059000),
    (2024, 'NT', 2,   50597.00, 101198.00::numeric(19,2), 0.086000),
    (2024, 'NT', 3,  101198.00, 164525.00::numeric(19,2), 0.122000),
    (2024, 'NT', 4,  164525.00, NULL::numeric(19,2), 0.140500),

    (2024, 'NU', 1,       0.00, 53268.00::numeric(19,2), 0.040000),
    (2024, 'NU', 2,   53268.00, 106537.00::numeric(19,2), 0.070000),
    (2024, 'NU', 3,  106537.00, 173205.00::numeric(19,2), 0.090000),
    (2024, 'NU', 4,  173205.00, NULL::numeric(19,2), 0.115000),

    (2024, 'YT', 1,       0.00, 55867.00::numeric(19,2), 0.064000),
    (2024, 'YT', 2,   55867.00, 111733.00::numeric(19,2), 0.090000),
    (2024, 'YT', 3,  111733.00, 173205.00::numeric(19,2), 0.109000),
    (2024, 'YT', 4,  173205.00, 500000.00::numeric(19,2), 0.128000),
    (2024, 'YT', 5,  500000.00, NULL::numeric(19,2), 0.150000)
) AS src (TaxYear, JurisdictionCode, Ordinal, LowerBound, UpperBound, Rate)
    ON  tgt.TaxYear          = src.TaxYear
    AND tgt.JurisdictionCode = src.JurisdictionCode
    AND tgt.Ordinal          = src.Ordinal
WHEN MATCHED THEN
    UPDATE SET LowerBound = src.LowerBound,
               UpperBound = src.UpperBound,
               Rate       = src.Rate
WHEN NOT MATCHED THEN
    INSERT (TaxYear, JurisdictionCode, Ordinal, LowerBound, UpperBound, Rate)
    VALUES (src.TaxYear, src.JurisdictionCode, src.Ordinal,
            src.LowerBound, src.UpperBound, src.Rate);

/*==============================================================================
  CPP / EI parameters

  CPP2 did not exist before 2024, which is why the 2023 row carries a zero
  rate and a zero YAMPE - tax.fn_CPP2Contribution reads that as "not in force".
==============================================================================*/
MERGE INTO ref.payrollrate AS tgt
USING (VALUES
    -- year  CPPRate   exempt    YMPE      CPP2Rate  YAMPE     EIRate    EIRateQC  MIE       EIMult
    (2023, 0.059500, 3500.00, 66600.00, 0.000000,     0.00, 0.016300, 0.012700, 61500.00, 1.4000),
    (2024, 0.059500, 3500.00, 68500.00, 0.040000, 73200.00, 0.016600, 0.013200, 63200.00, 1.4000),
    (2025, 0.059500, 3500.00, 71300.00, 0.040000, 81200.00, 0.016400, 0.013100, 65700.00, 1.4000)
) AS src (TaxYear, CPPRate, CPPBasicExemption, YMPE, CPP2Rate, YAMPE,
          EIRate, EIRateQuebec, EIMaxInsurableEarnings, EmployerEIMultiplier)
    ON tgt.TaxYear = src.TaxYear
WHEN MATCHED THEN
    UPDATE SET CPPRate                = src.CPPRate,
               CPPBasicExemption      = src.CPPBasicExemption,
               YMPE                   = src.YMPE,
               CPP2Rate               = src.CPP2Rate,
               YAMPE                  = src.YAMPE,
               EIRate                 = src.EIRate,
               EIRateQuebec           = src.EIRateQuebec,
               EIMaxInsurableEarnings = src.EIMaxInsurableEarnings,
               EmployerEIMultiplier   = src.EmployerEIMultiplier
WHEN NOT MATCHED THEN
    INSERT (TaxYear, CPPRate, CPPBasicExemption, YMPE, CPP2Rate, YAMPE,
            EIRate, EIRateQuebec, EIMaxInsurableEarnings, EmployerEIMultiplier)
    VALUES (src.TaxYear, src.CPPRate, src.CPPBasicExemption, src.YMPE,
            src.CPP2Rate, src.YAMPE, src.EIRate, src.EIRateQuebec,
            src.EIMaxInsurableEarnings, src.EmployerEIMultiplier);

/*==============================================================================
  Slip types and their boxes
==============================================================================*/
MERGE INTO ref.sliptype AS tgt
USING (VALUES
    ('T4',    'Statement of Remuneration Paid',                'Employer'),
    ('T4A',   'Statement of Pension, Retirement, Annuity and Other Income', 'Payer'),
    ('T5',    'Statement of Investment Income',                'Financial institution'),
    ('T3',    'Statement of Trust Income Allocations',         'Trust'),
    ('T5008', 'Statement of Securities Transactions',          'Broker'),
    ('T2202', 'Tuition and Enrolment Certificate',             'Educational institution')
) AS src (SlipTypeCode, Description, IssuedBy)
    ON tgt.SlipTypeCode = src.SlipTypeCode
WHEN MATCHED THEN
    UPDATE SET Description = src.Description, IssuedBy = src.IssuedBy
WHEN NOT MATCHED THEN
    INSERT (SlipTypeCode, Description, IssuedBy)
    VALUES (src.SlipTypeCode, src.Description, src.IssuedBy);

MERGE INTO ref.slipboxdefinition AS tgt
USING (VALUES
    -- T4
    ('T4',    '14',  'Employment income',                   'Employment'),
    ('T4',    '16',  'Employee CPP contributions',          'CPP'),
    ('T4',    '16A', 'Employee CPP2 contributions',         'CPP'),
    ('T4',    '18',  'Employee EI premiums',                'EI'),
    ('T4',    '20',  'RPP contributions',                   'Deduction'),
    ('T4',    '22',  'Income tax deducted',                 'TaxWithheld'),
    ('T4',    '24',  'EI insurable earnings',               'NonIncome'),
    ('T4',    '26',  'CPP pensionable earnings',            'NonIncome'),
    ('T4',    '44',  'Union dues',                          'Deduction'),
    -- T4A
    ('T4A',   '016', 'Pension or superannuation',           'Pension'),
    ('T4A',   '020', 'Self-employed commissions',           'SelfEmployment'),
    ('T4A',   '022', 'Income tax deducted',                 'TaxWithheld'),
    ('T4A',   '048', 'Fees for services',                   'SelfEmployment'),
    -- T5
    ('T5',    '13',  'Interest from Canadian sources',      'Investment'),
    ('T5',    '10',  'Actual amount of dividends other than eligible', 'Investment'),
    ('T5',    '24',  'Actual amount of eligible dividends', 'Investment'),
    ('T5',    '25',  'Taxable amount of eligible dividends','NonIncome'),
    ('T5',    '26',  'Dividend tax credit',                 'NonIncome'),
    -- T3
    ('T3',    '21',  'Capital gains',                       'Investment'),
    ('T3',    '26',  'Other income',                        'Other'),
    ('T3',    '49',  'Actual amount of eligible dividends', 'Investment'),
    -- T5008
    ('T5008', '20',  'Cost or book value',                  'NonIncome'),
    ('T5008', '21',  'Proceeds of disposition',             'Investment'),
    -- T2202
    ('T2202', 'A',   'Eligible tuition fees',               'Deduction')
) AS src (SlipTypeCode, BoxNumber, Label, IncomeCategory)
    ON tgt.SlipTypeCode = src.SlipTypeCode AND tgt.BoxNumber = src.BoxNumber
WHEN MATCHED THEN
    UPDATE SET Label = src.Label, IncomeCategory = src.IncomeCategory
WHEN NOT MATCHED THEN
    INSERT (SlipTypeCode, BoxNumber, Label, IncomeCategory)
    VALUES (src.SlipTypeCode, src.BoxNumber, src.Label, src.IncomeCategory);

/*==============================================================================
  Chart-of-accounts types
==============================================================================*/
MERGE INTO ref.accounttype AS tgt
USING (VALUES
    ('Asset',     'Asset',                'D', 0, 1),
    ('Liability', 'Liability',            'C', 0, 2),
    ('Equity',    'Equity',               'C', 0, 3),
    ('Revenue',   'Revenue',              'C', 1, 4),
    ('Expense',   'Operating expense',    'D', 1, 5),
    ('COGS',      'Cost of goods sold',   'D', 1, 6)
) AS src (AccountTypeCode, Description, NormalBalance, IsNominal, BalanceSheetOrder)
    ON tgt.AccountTypeCode = src.AccountTypeCode
WHEN MATCHED THEN
    UPDATE SET Description       = src.Description,
               NormalBalance     = src.NormalBalance,
               IsNominal         = src.IsNominal,
               BalanceSheetOrder = src.BalanceSheetOrder
WHEN NOT MATCHED THEN
    INSERT (AccountTypeCode, Description, NormalBalance, IsNominal, BalanceSheetOrder)
    VALUES (src.AccountTypeCode, src.Description, src.NormalBalance,
            src.IsNominal, src.BalanceSheetOrder);

/*==============================================================================
  GST/HST filing frequencies
==============================================================================*/
MERGE INTO ref.filingfrequency AS tgt
USING (VALUES
    ('Monthly',   'Monthly',   12),
    ('Quarterly', 'Quarterly',  4),
    ('Annual',    'Annual',     1)
) AS src (FrequencyCode, Description, PeriodsPerYear)
    ON tgt.FrequencyCode = src.FrequencyCode
WHEN MATCHED THEN
    UPDATE SET Description = src.Description, PeriodsPerYear = src.PeriodsPerYear
WHEN NOT MATCHED THEN
    INSERT (FrequencyCode, Description, PeriodsPerYear)
    VALUES (src.FrequencyCode, src.Description, src.PeriodsPerYear);

/*==============================================================================
  Non-refundable credits

  CreditRate is stored per row because a credit is claimed at the lowest
  bracket rate of its jurisdiction, and that rate changes: the federal rate is
  15% for 2023-2024 and 14.5% for 2025, and Alberta's drops to 8% in 2025.
==============================================================================*/
MERGE INTO ref.nonrefundablecredit AS tgt
USING (VALUES
    -- Federal
    ('BPA', 2023, 'CA', 'Basic personal amount',    15000.00, 0.150000),
    ('BPA', 2024, 'CA', 'Basic personal amount',    15705.00, 0.150000),
    ('BPA', 2025, 'CA', 'Basic personal amount',    16129.00, 0.145000),
    ('CEA', 2023, 'CA', 'Canada employment amount',  1368.00, 0.150000),
    ('CEA', 2024, 'CA', 'Canada employment amount',  1433.00, 0.150000),
    ('CEA', 2025, 'CA', 'Canada employment amount',  1471.00, 0.145000),
    ('CPP', 2024, 'CA', 'CPP contributions',         3867.50, 0.150000),
    ('EI',  2024, 'CA', 'EI premiums',               1049.12, 0.150000),
    -- Ontario
    ('BPA', 2023, 'ON', 'Basic personal amount',    11865.00, 0.050500),
    ('BPA', 2024, 'ON', 'Basic personal amount',    12399.00, 0.050500),
    ('BPA', 2025, 'ON', 'Basic personal amount',    12747.00, 0.050500),
    -- British Columbia
    ('BPA', 2023, 'BC', 'Basic personal amount',    11981.00, 0.050600),
    ('BPA', 2024, 'BC', 'Basic personal amount',    12580.00, 0.050600),
    ('BPA', 2025, 'BC', 'Basic personal amount',    12932.00, 0.050600),
    -- Alberta
    ('BPA', 2023, 'AB', 'Basic personal amount',    21003.00, 0.100000),
    ('BPA', 2024, 'AB', 'Basic personal amount',    21885.00, 0.100000),
    ('BPA', 2025, 'AB', 'Basic personal amount',    22323.00, 0.080000),
    -- Quebec
    ('BPA', 2023, 'QC', 'Basic personal amount',    17183.00, 0.140000),
    ('BPA', 2024, 'QC', 'Basic personal amount',    18056.00, 0.140000),
    ('BPA', 2025, 'QC', 'Basic personal amount',    18571.00, 0.140000)
) AS src (CreditCode, TaxYear, JurisdictionCode, Description, MaxAmount, CreditRate)
    ON  tgt.CreditCode       = src.CreditCode
    AND tgt.TaxYear          = src.TaxYear
    AND tgt.JurisdictionCode = src.JurisdictionCode
WHEN MATCHED THEN
    UPDATE SET Description = src.Description,
               MaxAmount   = src.MaxAmount,
               CreditRate  = src.CreditRate
WHEN NOT MATCHED THEN
    INSERT (CreditCode, TaxYear, JurisdictionCode, Description, MaxAmount, CreditRate)
    VALUES (src.CreditCode, src.TaxYear, src.JurisdictionCode,
            src.Description, src.MaxAmount, src.CreditRate);

/*==============================================================================
  Statutory holidays for 2024 and 2025

  'CA' rows are the federal/national days that apply everywhere;
  province-coded rows add the days observed only in that jurisdiction.
  util.fn_BusinessDaysBetween unions the two.
==============================================================================*/
MERGE INTO ref.statutoryholiday AS tgt
USING (VALUES
    -- 2024 national
    (DATE '2024-01-01', 'New Year''s Day',                              'CA'),
    (DATE '2024-03-29', 'Good Friday',                                  'CA'),
    (DATE '2024-07-01', 'Canada Day',                                   'CA'),
    (DATE '2024-09-02', 'Labour Day',                                   'CA'),
    (DATE '2024-09-30', 'National Day for Truth and Reconciliation',    'CA'),
    (DATE '2024-10-14', 'Thanksgiving',                                 'CA'),
    (DATE '2024-11-11', 'Remembrance Day',                              'CA'),
    (DATE '2024-12-25', 'Christmas Day',                                'CA'),
    (DATE '2024-12-26', 'Boxing Day',                                   'CA'),
    -- 2025 national
    (DATE '2025-01-01', 'New Year''s Day',                              'CA'),
    (DATE '2025-04-18', 'Good Friday',                                  'CA'),
    (DATE '2025-07-01', 'Canada Day',                                   'CA'),
    (DATE '2025-09-01', 'Labour Day',                                   'CA'),
    (DATE '2025-09-30', 'National Day for Truth and Reconciliation',    'CA'),
    (DATE '2025-10-13', 'Thanksgiving',                                 'CA'),
    (DATE '2025-11-11', 'Remembrance Day',                              'CA'),
    (DATE '2025-12-25', 'Christmas Day',                                'CA'),
    (DATE '2025-12-26', 'Boxing Day',                                   'CA'),
    -- Ontario
    (DATE '2024-02-19', 'Family Day',                                   'ON'),
    (DATE '2024-05-20', 'Victoria Day',                                 'ON'),
    (DATE '2024-08-05', 'Civic Holiday',                                'ON'),
    (DATE '2025-02-17', 'Family Day',                                   'ON'),
    (DATE '2025-05-19', 'Victoria Day',                                 'ON'),
    (DATE '2025-08-04', 'Civic Holiday',                                'ON'),
    -- British Columbia
    (DATE '2024-02-19', 'Family Day',                                   'BC'),
    (DATE '2024-05-20', 'Victoria Day',                                 'BC'),
    (DATE '2024-08-05', 'British Columbia Day',                         'BC'),
    (DATE '2025-02-17', 'Family Day',                                   'BC'),
    (DATE '2025-05-19', 'Victoria Day',                                 'BC'),
    (DATE '2025-08-04', 'British Columbia Day',                         'BC'),
    -- Quebec
    (DATE '2024-05-20', 'National Patriots'' Day',                      'QC'),
    (DATE '2024-06-24', 'Saint-Jean-Baptiste Day',                      'QC'),
    (DATE '2025-05-19', 'National Patriots'' Day',                      'QC'),
    (DATE '2025-06-24', 'Saint-Jean-Baptiste Day',                      'QC'),
    -- Alberta
    (DATE '2024-02-19', 'Family Day',                                   'AB'),
    (DATE '2024-05-20', 'Victoria Day',                                 'AB'),
    (DATE '2024-08-05', 'Heritage Day',                                 'AB'),
    (DATE '2025-02-17', 'Family Day',                                   'AB'),
    (DATE '2025-05-19', 'Victoria Day',                                 'AB'),
    (DATE '2025-08-04', 'Heritage Day',                                 'AB')
) AS src (HolidayDate, HolidayName, JurisdictionCode)
    ON tgt.HolidayDate = src.HolidayDate AND tgt.JurisdictionCode = src.JurisdictionCode
WHEN MATCHED THEN
    UPDATE SET HolidayName = src.HolidayName
WHEN NOT MATCHED THEN
    INSERT (HolidayDate, HolidayName, JurisdictionCode)
    VALUES (src.HolidayDate, src.HolidayName, src.JurisdictionCode);

DO $$ BEGIN RAISE NOTICE '020 reference data seeded.'; END $$;