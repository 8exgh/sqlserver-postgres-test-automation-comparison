/*==============================================================================
  020 - Reference data seed

  ---------------------------------------------------------------------------
  ACCURACY NOTICE

  The rates, brackets and thresholds below are drawn from CRA and provincial
  published figures for 2023-2025 and are here to make the calculations behave
  realistically under test. They are FIXTURE DATA. They have not been verified
  for completeness against every mid-year amendment, surtax, or provincial
  levy, and this schema is not a tax engine. Do not rely on any figure here for
  an actual filing.
  ---------------------------------------------------------------------------

  Bracket coverage is deliberately uneven, and 099_verify.sql asserts exactly
  this shape:
      federal ('CA')     - 2023, 2024, 2025
      ON, BC, AB, QC     - 2023, 2024, 2025
      all other provinces- 2024 only

  Every statement is a MERGE, so the file is re-runnable and converges on the
  same state rather than duplicating or failing.
==============================================================================*/
USE CdnTaxPractice;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/*==============================================================================
  Provinces and territories
==============================================================================*/
MERGE ref.Province AS tgt
USING (VALUES
    ('AB', N'Alberta',                   0,  1),
    ('BC', N'British Columbia',          0,  2),
    ('MB', N'Manitoba',                  0,  3),
    ('NB', N'New Brunswick',             0,  4),
    ('NL', N'Newfoundland and Labrador', 0,  5),
    ('NS', N'Nova Scotia',               0,  6),
    ('NT', N'Northwest Territories',     1,  7),
    ('NU', N'Nunavut',                   1,  8),
    ('ON', N'Ontario',                   0,  9),
    ('PE', N'Prince Edward Island',      0, 10),
    ('QC', N'Quebec',                    0, 11),
    ('SK', N'Saskatchewan',              0, 12),
    ('YT', N'Yukon',                     1, 13)
) AS src (ProvinceCode, ProvinceName, IsTerritory, SortOrder)
    ON tgt.ProvinceCode = src.ProvinceCode
WHEN MATCHED THEN
    UPDATE SET ProvinceName = src.ProvinceName,
               IsTerritory  = src.IsTerritory,
               SortOrder    = src.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ProvinceCode, ProvinceName, IsTerritory, SortOrder)
    VALUES (src.ProvinceCode, src.ProvinceName, src.IsTerritory, src.SortOrder);
GO

/*==============================================================================
  Jurisdictions: the federal government plus one per province
==============================================================================*/
MERGE ref.Jurisdiction AS tgt
USING (
    SELECT 'CA' AS JurisdictionCode, N'Canada (federal)' AS JurisdictionName,
           1 AS IsFederal, CONVERT(CHAR(2), NULL) AS ProvinceCode
    UNION ALL
    SELECT p.ProvinceCode, p.ProvinceName, 0, p.ProvinceCode
    FROM   ref.Province AS p
) AS src
    ON tgt.JurisdictionCode = src.JurisdictionCode
WHEN MATCHED THEN
    UPDATE SET JurisdictionName = src.JurisdictionName,
               IsFederal        = src.IsFederal,
               ProvinceCode     = src.ProvinceCode
WHEN NOT MATCHED BY TARGET THEN
    INSERT (JurisdictionCode, JurisdictionName, IsFederal, ProvinceCode)
    VALUES (src.JurisdictionCode, src.JurisdictionName, src.IsFederal, src.ProvinceCode);
GO

/*==============================================================================
  Sales tax rates

  HST provinces charge a single blended rate; the rest charge 5% GST with an
  optional provincial tax on top. Nova Scotia's reduction from 15% to 14% on
  2025-04-01 is seeded as two date ranges, which is the whole reason
  ref.SalesTaxRate is a range table.
==============================================================================*/
MERGE ref.SalesTaxRate AS tgt
USING (VALUES
    --  prov  from          to             GST      HST      PST      QST
    ('AB', '2023-01-01', CONVERT(DATE, NULL), 0.05000, 0.00000, 0.00000, 0.00000),
    ('BC', '2023-01-01', CONVERT(DATE, NULL), 0.05000, 0.00000, 0.07000, 0.00000),
    ('MB', '2023-01-01', CONVERT(DATE, NULL), 0.05000, 0.00000, 0.07000, 0.00000),
    ('NB', '2023-01-01', CONVERT(DATE, NULL), 0.00000, 0.15000, 0.00000, 0.00000),
    ('NL', '2023-01-01', CONVERT(DATE, NULL), 0.00000, 0.15000, 0.00000, 0.00000),
    ('NS', '2023-01-01', CONVERT(DATE, '2025-04-01'), 0.00000, 0.15000, 0.00000, 0.00000),
    ('NS', '2025-04-01', CONVERT(DATE, NULL), 0.00000, 0.14000, 0.00000, 0.00000),
    ('NT', '2023-01-01', CONVERT(DATE, NULL), 0.05000, 0.00000, 0.00000, 0.00000),
    ('NU', '2023-01-01', CONVERT(DATE, NULL), 0.05000, 0.00000, 0.00000, 0.00000),
    ('ON', '2023-01-01', CONVERT(DATE, NULL), 0.00000, 0.13000, 0.00000, 0.00000),
    ('PE', '2023-01-01', CONVERT(DATE, NULL), 0.00000, 0.15000, 0.00000, 0.00000),
    ('QC', '2023-01-01', CONVERT(DATE, NULL), 0.05000, 0.00000, 0.00000, 0.09975),
    ('SK', '2023-01-01', CONVERT(DATE, NULL), 0.05000, 0.00000, 0.06000, 0.00000),
    ('YT', '2023-01-01', CONVERT(DATE, NULL), 0.05000, 0.00000, 0.00000, 0.00000)
) AS src (ProvinceCode, EffectiveFrom, EffectiveTo, GSTRate, HSTRate, PSTRate, QSTRate)
    ON  tgt.ProvinceCode  = src.ProvinceCode
    AND tgt.EffectiveFrom = src.EffectiveFrom
WHEN MATCHED THEN
    UPDATE SET EffectiveTo = src.EffectiveTo,
               GSTRate     = src.GSTRate,
               HSTRate     = src.HSTRate,
               PSTRate     = src.PSTRate,
               QSTRate     = src.QSTRate
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ProvinceCode, EffectiveFrom, EffectiveTo, GSTRate, HSTRate, PSTRate, QSTRate)
    VALUES (src.ProvinceCode, src.EffectiveFrom, src.EffectiveTo,
            src.GSTRate, src.HSTRate, src.PSTRate, src.QSTRate);
GO

/*==============================================================================
  Tax years

  Deadlines that fall on a weekend move to the next business day, which is why
  the self-employment and RRSP dates below are not always June 15 / March 1.
  2023 is left unlocked here and locked at the end of 021, after its returns
  have been calculated.
==============================================================================*/
MERGE ref.TaxYear AS tgt
USING (VALUES
    (2023, '2024-04-30', '2024-06-17', '2024-02-29', 3000.00),
    (2024, '2025-04-30', '2025-06-16', '2025-03-03', 3000.00),
    (2025, '2026-04-30', '2026-06-15', '2026-03-02', 3000.00)
) AS src (TaxYear, T1FilingDeadline, SelfEmployedDeadline, RRSPDeadline, InstallmentThreshold)
    ON tgt.TaxYear = src.TaxYear
WHEN MATCHED THEN
    UPDATE SET T1FilingDeadline     = src.T1FilingDeadline,
               SelfEmployedDeadline = src.SelfEmployedDeadline,
               RRSPDeadline         = src.RRSPDeadline,
               InstallmentThreshold = src.InstallmentThreshold
WHEN NOT MATCHED BY TARGET THEN
    INSERT (TaxYear, T1FilingDeadline, SelfEmployedDeadline, RRSPDeadline, InstallmentThreshold)
    VALUES (src.TaxYear, src.T1FilingDeadline, src.SelfEmployedDeadline,
            src.RRSPDeadline, src.InstallmentThreshold);
GO

/*==============================================================================
  Tax brackets

  A NULL UpperBound marks the top bracket. The federal 2025 lowest rate is
  seeded as 14.5%: the statutory rate dropped from 15% to 14% part-way through
  2025, and 14.5% is the full-year effective rate that results.
==============================================================================*/
MERGE ref.TaxBracket AS tgt
USING (VALUES
    /*---------------------------- FEDERAL ---------------------------------*/
    (2023, 'CA', 1,       0.00, CONVERT(DECIMAL(19,2),  53359.00), 0.150000),
    (2023, 'CA', 2,   53359.00, CONVERT(DECIMAL(19,2), 106717.00), 0.205000),
    (2023, 'CA', 3,  106717.00, CONVERT(DECIMAL(19,2), 165430.00), 0.260000),
    (2023, 'CA', 4,  165430.00, CONVERT(DECIMAL(19,2), 235675.00), 0.290000),
    (2023, 'CA', 5,  235675.00, CONVERT(DECIMAL(19,2),      NULL), 0.330000),

    (2024, 'CA', 1,       0.00, CONVERT(DECIMAL(19,2),  55867.00), 0.150000),
    (2024, 'CA', 2,   55867.00, CONVERT(DECIMAL(19,2), 111733.00), 0.205000),
    (2024, 'CA', 3,  111733.00, CONVERT(DECIMAL(19,2), 173205.00), 0.260000),
    (2024, 'CA', 4,  173205.00, CONVERT(DECIMAL(19,2), 246752.00), 0.290000),
    (2024, 'CA', 5,  246752.00, CONVERT(DECIMAL(19,2),      NULL), 0.330000),

    (2025, 'CA', 1,       0.00, CONVERT(DECIMAL(19,2),  57375.00), 0.145000),
    (2025, 'CA', 2,   57375.00, CONVERT(DECIMAL(19,2), 114750.00), 0.205000),
    (2025, 'CA', 3,  114750.00, CONVERT(DECIMAL(19,2), 177882.00), 0.260000),
    (2025, 'CA', 4,  177882.00, CONVERT(DECIMAL(19,2), 253414.00), 0.290000),
    (2025, 'CA', 5,  253414.00, CONVERT(DECIMAL(19,2),      NULL), 0.330000),

    /*---------------------------- ONTARIO ---------------------------------*/
    (2023, 'ON', 1,       0.00, CONVERT(DECIMAL(19,2),  49231.00), 0.050500),
    (2023, 'ON', 2,   49231.00, CONVERT(DECIMAL(19,2),  98463.00), 0.091500),
    (2023, 'ON', 3,   98463.00, CONVERT(DECIMAL(19,2), 150000.00), 0.111600),
    (2023, 'ON', 4,  150000.00, CONVERT(DECIMAL(19,2), 220000.00), 0.121600),
    (2023, 'ON', 5,  220000.00, CONVERT(DECIMAL(19,2),      NULL), 0.131600),

    (2024, 'ON', 1,       0.00, CONVERT(DECIMAL(19,2),  51446.00), 0.050500),
    (2024, 'ON', 2,   51446.00, CONVERT(DECIMAL(19,2), 102894.00), 0.091500),
    (2024, 'ON', 3,  102894.00, CONVERT(DECIMAL(19,2), 150000.00), 0.111600),
    (2024, 'ON', 4,  150000.00, CONVERT(DECIMAL(19,2), 220000.00), 0.121600),
    (2024, 'ON', 5,  220000.00, CONVERT(DECIMAL(19,2),      NULL), 0.131600),

    (2025, 'ON', 1,       0.00, CONVERT(DECIMAL(19,2),  52886.00), 0.050500),
    (2025, 'ON', 2,   52886.00, CONVERT(DECIMAL(19,2), 105775.00), 0.091500),
    (2025, 'ON', 3,  105775.00, CONVERT(DECIMAL(19,2), 150000.00), 0.111600),
    (2025, 'ON', 4,  150000.00, CONVERT(DECIMAL(19,2), 220000.00), 0.121600),
    (2025, 'ON', 5,  220000.00, CONVERT(DECIMAL(19,2),      NULL), 0.131600),

    /*------------------------ BRITISH COLUMBIA ----------------------------*/
    (2023, 'BC', 1,       0.00, CONVERT(DECIMAL(19,2),  45654.00), 0.050600),
    (2023, 'BC', 2,   45654.00, CONVERT(DECIMAL(19,2),  91310.00), 0.077000),
    (2023, 'BC', 3,   91310.00, CONVERT(DECIMAL(19,2), 104835.00), 0.105000),
    (2023, 'BC', 4,  104835.00, CONVERT(DECIMAL(19,2), 127299.00), 0.122900),
    (2023, 'BC', 5,  127299.00, CONVERT(DECIMAL(19,2), 172602.00), 0.147000),
    (2023, 'BC', 6,  172602.00, CONVERT(DECIMAL(19,2), 240716.00), 0.168000),
    (2023, 'BC', 7,  240716.00, CONVERT(DECIMAL(19,2),      NULL), 0.205000),

    (2024, 'BC', 1,       0.00, CONVERT(DECIMAL(19,2),  47937.00), 0.050600),
    (2024, 'BC', 2,   47937.00, CONVERT(DECIMAL(19,2),  95875.00), 0.077000),
    (2024, 'BC', 3,   95875.00, CONVERT(DECIMAL(19,2), 110076.00), 0.105000),
    (2024, 'BC', 4,  110076.00, CONVERT(DECIMAL(19,2), 133664.00), 0.122900),
    (2024, 'BC', 5,  133664.00, CONVERT(DECIMAL(19,2), 181232.00), 0.147000),
    (2024, 'BC', 6,  181232.00, CONVERT(DECIMAL(19,2), 252752.00), 0.168000),
    (2024, 'BC', 7,  252752.00, CONVERT(DECIMAL(19,2),      NULL), 0.205000),

    (2025, 'BC', 1,       0.00, CONVERT(DECIMAL(19,2),  49279.00), 0.050600),
    (2025, 'BC', 2,   49279.00, CONVERT(DECIMAL(19,2),  98560.00), 0.077000),
    (2025, 'BC', 3,   98560.00, CONVERT(DECIMAL(19,2), 113158.00), 0.105000),
    (2025, 'BC', 4,  113158.00, CONVERT(DECIMAL(19,2), 137407.00), 0.122900),
    (2025, 'BC', 5,  137407.00, CONVERT(DECIMAL(19,2), 186306.00), 0.147000),
    (2025, 'BC', 6,  186306.00, CONVERT(DECIMAL(19,2), 259829.00), 0.168000),
    (2025, 'BC', 7,  259829.00, CONVERT(DECIMAL(19,2),      NULL), 0.205000),

    /*---------------------------- ALBERTA ---------------------------------*/
    (2023, 'AB', 1,       0.00, CONVERT(DECIMAL(19,2), 142292.00), 0.100000),
    (2023, 'AB', 2,  142292.00, CONVERT(DECIMAL(19,2), 170751.00), 0.120000),
    (2023, 'AB', 3,  170751.00, CONVERT(DECIMAL(19,2), 227668.00), 0.130000),
    (2023, 'AB', 4,  227668.00, CONVERT(DECIMAL(19,2), 341502.00), 0.140000),
    (2023, 'AB', 5,  341502.00, CONVERT(DECIMAL(19,2),      NULL), 0.150000),

    (2024, 'AB', 1,       0.00, CONVERT(DECIMAL(19,2), 148269.00), 0.100000),
    (2024, 'AB', 2,  148269.00, CONVERT(DECIMAL(19,2), 177922.00), 0.120000),
    (2024, 'AB', 3,  177922.00, CONVERT(DECIMAL(19,2), 237230.00), 0.130000),
    (2024, 'AB', 4,  237230.00, CONVERT(DECIMAL(19,2), 355845.00), 0.140000),
    (2024, 'AB', 5,  355845.00, CONVERT(DECIMAL(19,2),      NULL), 0.150000),

    -- Alberta added a new 8% first bracket in 2025.
    (2025, 'AB', 1,       0.00, CONVERT(DECIMAL(19,2),  60000.00), 0.080000),
    (2025, 'AB', 2,   60000.00, CONVERT(DECIMAL(19,2), 151234.00), 0.100000),
    (2025, 'AB', 3,  151234.00, CONVERT(DECIMAL(19,2), 181481.00), 0.120000),
    (2025, 'AB', 4,  181481.00, CONVERT(DECIMAL(19,2), 241974.00), 0.130000),
    (2025, 'AB', 5,  241974.00, CONVERT(DECIMAL(19,2), 362961.00), 0.140000),
    (2025, 'AB', 6,  362961.00, CONVERT(DECIMAL(19,2),      NULL), 0.150000),

    /*----------------------------- QUEBEC ---------------------------------*/
    (2023, 'QC', 1,       0.00, CONVERT(DECIMAL(19,2),  49275.00), 0.140000),
    (2023, 'QC', 2,   49275.00, CONVERT(DECIMAL(19,2),  98540.00), 0.190000),
    (2023, 'QC', 3,   98540.00, CONVERT(DECIMAL(19,2), 119910.00), 0.240000),
    (2023, 'QC', 4,  119910.00, CONVERT(DECIMAL(19,2),      NULL), 0.257500),

    (2024, 'QC', 1,       0.00, CONVERT(DECIMAL(19,2),  51780.00), 0.140000),
    (2024, 'QC', 2,   51780.00, CONVERT(DECIMAL(19,2), 103545.00), 0.190000),
    (2024, 'QC', 3,  103545.00, CONVERT(DECIMAL(19,2), 126000.00), 0.240000),
    (2024, 'QC', 4,  126000.00, CONVERT(DECIMAL(19,2),      NULL), 0.257500),

    (2025, 'QC', 1,       0.00, CONVERT(DECIMAL(19,2),  53255.00), 0.140000),
    (2025, 'QC', 2,   53255.00, CONVERT(DECIMAL(19,2), 106495.00), 0.190000),
    (2025, 'QC', 3,  106495.00, CONVERT(DECIMAL(19,2), 129590.00), 0.240000),
    (2025, 'QC', 4,  129590.00, CONVERT(DECIMAL(19,2),      NULL), 0.257500),

    /*----------------- REMAINING PROVINCES - 2024 ONLY --------------------*/
    (2024, 'MB', 1,       0.00, CONVERT(DECIMAL(19,2),  47000.00), 0.108000),
    (2024, 'MB', 2,   47000.00, CONVERT(DECIMAL(19,2), 100000.00), 0.127500),
    (2024, 'MB', 3,  100000.00, CONVERT(DECIMAL(19,2),      NULL), 0.174000),

    (2024, 'SK', 1,       0.00, CONVERT(DECIMAL(19,2),  52057.00), 0.105000),
    (2024, 'SK', 2,   52057.00, CONVERT(DECIMAL(19,2), 148734.00), 0.125000),
    (2024, 'SK', 3,  148734.00, CONVERT(DECIMAL(19,2),      NULL), 0.145000),

    (2024, 'NS', 1,       0.00, CONVERT(DECIMAL(19,2),  29590.00), 0.087900),
    (2024, 'NS', 2,   29590.00, CONVERT(DECIMAL(19,2),  59180.00), 0.149500),
    (2024, 'NS', 3,   59180.00, CONVERT(DECIMAL(19,2),  93000.00), 0.166700),
    (2024, 'NS', 4,   93000.00, CONVERT(DECIMAL(19,2), 150000.00), 0.175000),
    (2024, 'NS', 5,  150000.00, CONVERT(DECIMAL(19,2),      NULL), 0.210000),

    (2024, 'NB', 1,       0.00, CONVERT(DECIMAL(19,2),  49958.00), 0.094000),
    (2024, 'NB', 2,   49958.00, CONVERT(DECIMAL(19,2),  99916.00), 0.140000),
    (2024, 'NB', 3,   99916.00, CONVERT(DECIMAL(19,2), 185064.00), 0.160000),
    (2024, 'NB', 4,  185064.00, CONVERT(DECIMAL(19,2),      NULL), 0.195000),

    (2024, 'NL', 1,       0.00, CONVERT(DECIMAL(19,2),  43198.00), 0.087000),
    (2024, 'NL', 2,   43198.00, CONVERT(DECIMAL(19,2),  86395.00), 0.145000),
    (2024, 'NL', 3,   86395.00, CONVERT(DECIMAL(19,2), 154244.00), 0.158000),
    (2024, 'NL', 4,  154244.00, CONVERT(DECIMAL(19,2), 215943.00), 0.178000),
    (2024, 'NL', 5,  215943.00, CONVERT(DECIMAL(19,2), 275870.00), 0.198000),
    (2024, 'NL', 6,  275870.00, CONVERT(DECIMAL(19,2), 551739.00), 0.208000),
    (2024, 'NL', 7,  551739.00, CONVERT(DECIMAL(19,2),1103478.00), 0.213000),
    (2024, 'NL', 8, 1103478.00, CONVERT(DECIMAL(19,2),      NULL), 0.218000),

    (2024, 'PE', 1,       0.00, CONVERT(DECIMAL(19,2),  32656.00), 0.096500),
    (2024, 'PE', 2,   32656.00, CONVERT(DECIMAL(19,2),  64313.00), 0.136300),
    (2024, 'PE', 3,   64313.00, CONVERT(DECIMAL(19,2), 105000.00), 0.166500),
    (2024, 'PE', 4,  105000.00, CONVERT(DECIMAL(19,2), 140000.00), 0.180000),
    (2024, 'PE', 5,  140000.00, CONVERT(DECIMAL(19,2),      NULL), 0.187500),

    (2024, 'NT', 1,       0.00, CONVERT(DECIMAL(19,2),  50597.00), 0.059000),
    (2024, 'NT', 2,   50597.00, CONVERT(DECIMAL(19,2), 101198.00), 0.086000),
    (2024, 'NT', 3,  101198.00, CONVERT(DECIMAL(19,2), 164525.00), 0.122000),
    (2024, 'NT', 4,  164525.00, CONVERT(DECIMAL(19,2),      NULL), 0.140500),

    (2024, 'NU', 1,       0.00, CONVERT(DECIMAL(19,2),  53268.00), 0.040000),
    (2024, 'NU', 2,   53268.00, CONVERT(DECIMAL(19,2), 106537.00), 0.070000),
    (2024, 'NU', 3,  106537.00, CONVERT(DECIMAL(19,2), 173205.00), 0.090000),
    (2024, 'NU', 4,  173205.00, CONVERT(DECIMAL(19,2),      NULL), 0.115000),

    (2024, 'YT', 1,       0.00, CONVERT(DECIMAL(19,2),  55867.00), 0.064000),
    (2024, 'YT', 2,   55867.00, CONVERT(DECIMAL(19,2), 111733.00), 0.090000),
    (2024, 'YT', 3,  111733.00, CONVERT(DECIMAL(19,2), 173205.00), 0.109000),
    (2024, 'YT', 4,  173205.00, CONVERT(DECIMAL(19,2), 500000.00), 0.128000),
    (2024, 'YT', 5,  500000.00, CONVERT(DECIMAL(19,2),      NULL), 0.150000)
) AS src (TaxYear, JurisdictionCode, Ordinal, LowerBound, UpperBound, Rate)
    ON  tgt.TaxYear          = src.TaxYear
    AND tgt.JurisdictionCode = src.JurisdictionCode
    AND tgt.Ordinal          = src.Ordinal
WHEN MATCHED THEN
    UPDATE SET LowerBound = src.LowerBound,
               UpperBound = src.UpperBound,
               Rate       = src.Rate
WHEN NOT MATCHED BY TARGET THEN
    INSERT (TaxYear, JurisdictionCode, Ordinal, LowerBound, UpperBound, Rate)
    VALUES (src.TaxYear, src.JurisdictionCode, src.Ordinal,
            src.LowerBound, src.UpperBound, src.Rate);
GO

/*==============================================================================
  CPP / EI parameters

  CPP2 did not exist before 2024, which is why the 2023 row carries a zero
  rate and a zero YAMPE - tax.fn_CPP2Contribution reads that as "not in force".
==============================================================================*/
MERGE ref.PayrollRate AS tgt
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
WHEN NOT MATCHED BY TARGET THEN
    INSERT (TaxYear, CPPRate, CPPBasicExemption, YMPE, CPP2Rate, YAMPE,
            EIRate, EIRateQuebec, EIMaxInsurableEarnings, EmployerEIMultiplier)
    VALUES (src.TaxYear, src.CPPRate, src.CPPBasicExemption, src.YMPE,
            src.CPP2Rate, src.YAMPE, src.EIRate, src.EIRateQuebec,
            src.EIMaxInsurableEarnings, src.EmployerEIMultiplier);
GO

/*==============================================================================
  Slip types and their boxes
==============================================================================*/
MERGE ref.SlipType AS tgt
USING (VALUES
    (N'T4',    N'Statement of Remuneration Paid',                N'Employer'),
    (N'T4A',   N'Statement of Pension, Retirement, Annuity and Other Income', N'Payer'),
    (N'T5',    N'Statement of Investment Income',                N'Financial institution'),
    (N'T3',    N'Statement of Trust Income Allocations',         N'Trust'),
    (N'T5008', N'Statement of Securities Transactions',          N'Broker'),
    (N'T2202', N'Tuition and Enrolment Certificate',             N'Educational institution')
) AS src (SlipTypeCode, Description, IssuedBy)
    ON tgt.SlipTypeCode = src.SlipTypeCode
WHEN MATCHED THEN
    UPDATE SET Description = src.Description, IssuedBy = src.IssuedBy
WHEN NOT MATCHED BY TARGET THEN
    INSERT (SlipTypeCode, Description, IssuedBy)
    VALUES (src.SlipTypeCode, src.Description, src.IssuedBy);
GO

MERGE ref.SlipBoxDefinition AS tgt
USING (VALUES
    -- T4
    (N'T4',    N'14',  N'Employment income',                   N'Employment'),
    (N'T4',    N'16',  N'Employee CPP contributions',          N'CPP'),
    (N'T4',    N'16A', N'Employee CPP2 contributions',         N'CPP'),
    (N'T4',    N'18',  N'Employee EI premiums',                N'EI'),
    (N'T4',    N'20',  N'RPP contributions',                   N'Deduction'),
    (N'T4',    N'22',  N'Income tax deducted',                 N'TaxWithheld'),
    (N'T4',    N'24',  N'EI insurable earnings',               N'NonIncome'),
    (N'T4',    N'26',  N'CPP pensionable earnings',            N'NonIncome'),
    (N'T4',    N'44',  N'Union dues',                          N'Deduction'),
    -- T4A
    (N'T4A',   N'016', N'Pension or superannuation',           N'Pension'),
    (N'T4A',   N'020', N'Self-employed commissions',           N'SelfEmployment'),
    (N'T4A',   N'022', N'Income tax deducted',                 N'TaxWithheld'),
    (N'T4A',   N'048', N'Fees for services',                   N'SelfEmployment'),
    -- T5
    (N'T5',    N'13',  N'Interest from Canadian sources',      N'Investment'),
    (N'T5',    N'10',  N'Actual amount of dividends other than eligible', N'Investment'),
    (N'T5',    N'24',  N'Actual amount of eligible dividends', N'Investment'),
    (N'T5',    N'25',  N'Taxable amount of eligible dividends',N'NonIncome'),
    (N'T5',    N'26',  N'Dividend tax credit',                 N'NonIncome'),
    -- T3
    (N'T3',    N'21',  N'Capital gains',                       N'Investment'),
    (N'T3',    N'26',  N'Other income',                        N'Other'),
    (N'T3',    N'49',  N'Actual amount of eligible dividends', N'Investment'),
    -- T5008
    (N'T5008', N'20',  N'Cost or book value',                  N'NonIncome'),
    (N'T5008', N'21',  N'Proceeds of disposition',             N'Investment'),
    -- T2202
    (N'T2202', N'A',   N'Eligible tuition fees',               N'Deduction')
) AS src (SlipTypeCode, BoxNumber, Label, IncomeCategory)
    ON tgt.SlipTypeCode = src.SlipTypeCode AND tgt.BoxNumber = src.BoxNumber
WHEN MATCHED THEN
    UPDATE SET Label = src.Label, IncomeCategory = src.IncomeCategory
WHEN NOT MATCHED BY TARGET THEN
    INSERT (SlipTypeCode, BoxNumber, Label, IncomeCategory)
    VALUES (src.SlipTypeCode, src.BoxNumber, src.Label, src.IncomeCategory);
GO

/*==============================================================================
  Chart-of-accounts types
==============================================================================*/
MERGE ref.AccountType AS tgt
USING (VALUES
    (N'Asset',     N'Asset',                'D', 0, 1),
    (N'Liability', N'Liability',            'C', 0, 2),
    (N'Equity',    N'Equity',               'C', 0, 3),
    (N'Revenue',   N'Revenue',              'C', 1, 4),
    (N'Expense',   N'Operating expense',    'D', 1, 5),
    (N'COGS',      N'Cost of goods sold',   'D', 1, 6)
) AS src (AccountTypeCode, Description, NormalBalance, IsNominal, BalanceSheetOrder)
    ON tgt.AccountTypeCode = src.AccountTypeCode
WHEN MATCHED THEN
    UPDATE SET Description       = src.Description,
               NormalBalance     = src.NormalBalance,
               IsNominal         = src.IsNominal,
               BalanceSheetOrder = src.BalanceSheetOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (AccountTypeCode, Description, NormalBalance, IsNominal, BalanceSheetOrder)
    VALUES (src.AccountTypeCode, src.Description, src.NormalBalance,
            src.IsNominal, src.BalanceSheetOrder);
GO

/*==============================================================================
  GST/HST filing frequencies
==============================================================================*/
MERGE ref.FilingFrequency AS tgt
USING (VALUES
    (N'Monthly',   N'Monthly',   12),
    (N'Quarterly', N'Quarterly',  4),
    (N'Annual',    N'Annual',     1)
) AS src (FrequencyCode, Description, PeriodsPerYear)
    ON tgt.FrequencyCode = src.FrequencyCode
WHEN MATCHED THEN
    UPDATE SET Description = src.Description, PeriodsPerYear = src.PeriodsPerYear
WHEN NOT MATCHED BY TARGET THEN
    INSERT (FrequencyCode, Description, PeriodsPerYear)
    VALUES (src.FrequencyCode, src.Description, src.PeriodsPerYear);
GO

/*==============================================================================
  Non-refundable credits

  CreditRate is stored per row because a credit is claimed at the lowest
  bracket rate of its jurisdiction, and that rate changes: the federal rate is
  15% for 2023-2024 and 14.5% for 2025, and Alberta's drops to 8% in 2025.
==============================================================================*/
MERGE ref.NonRefundableCredit AS tgt
USING (VALUES
    -- Federal
    (N'BPA', 2023, 'CA', N'Basic personal amount',    15000.00, 0.150000),
    (N'BPA', 2024, 'CA', N'Basic personal amount',    15705.00, 0.150000),
    (N'BPA', 2025, 'CA', N'Basic personal amount',    16129.00, 0.145000),
    (N'CEA', 2023, 'CA', N'Canada employment amount',  1368.00, 0.150000),
    (N'CEA', 2024, 'CA', N'Canada employment amount',  1433.00, 0.150000),
    (N'CEA', 2025, 'CA', N'Canada employment amount',  1471.00, 0.145000),
    (N'CPP', 2024, 'CA', N'CPP contributions',         3867.50, 0.150000),
    (N'EI',  2024, 'CA', N'EI premiums',               1049.12, 0.150000),
    -- Ontario
    (N'BPA', 2023, 'ON', N'Basic personal amount',    11865.00, 0.050500),
    (N'BPA', 2024, 'ON', N'Basic personal amount',    12399.00, 0.050500),
    (N'BPA', 2025, 'ON', N'Basic personal amount',    12747.00, 0.050500),
    -- British Columbia
    (N'BPA', 2023, 'BC', N'Basic personal amount',    11981.00, 0.050600),
    (N'BPA', 2024, 'BC', N'Basic personal amount',    12580.00, 0.050600),
    (N'BPA', 2025, 'BC', N'Basic personal amount',    12932.00, 0.050600),
    -- Alberta
    (N'BPA', 2023, 'AB', N'Basic personal amount',    21003.00, 0.100000),
    (N'BPA', 2024, 'AB', N'Basic personal amount',    21885.00, 0.100000),
    (N'BPA', 2025, 'AB', N'Basic personal amount',    22323.00, 0.080000),
    -- Quebec
    (N'BPA', 2023, 'QC', N'Basic personal amount',    17183.00, 0.140000),
    (N'BPA', 2024, 'QC', N'Basic personal amount',    18056.00, 0.140000),
    (N'BPA', 2025, 'QC', N'Basic personal amount',    18571.00, 0.140000)
) AS src (CreditCode, TaxYear, JurisdictionCode, Description, MaxAmount, CreditRate)
    ON  tgt.CreditCode       = src.CreditCode
    AND tgt.TaxYear          = src.TaxYear
    AND tgt.JurisdictionCode = src.JurisdictionCode
WHEN MATCHED THEN
    UPDATE SET Description = src.Description,
               MaxAmount   = src.MaxAmount,
               CreditRate  = src.CreditRate
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CreditCode, TaxYear, JurisdictionCode, Description, MaxAmount, CreditRate)
    VALUES (src.CreditCode, src.TaxYear, src.JurisdictionCode,
            src.Description, src.MaxAmount, src.CreditRate);
GO

/*==============================================================================
  Statutory holidays for 2024 and 2025

  'CA' rows are the federal/national days that apply everywhere;
  province-coded rows add the days observed only in that jurisdiction.
  util.fn_BusinessDaysBetween unions the two.
==============================================================================*/
MERGE ref.StatutoryHoliday AS tgt
USING (VALUES
    -- 2024 national
    ('2024-01-01', N'New Year''s Day',                              'CA'),
    ('2024-03-29', N'Good Friday',                                  'CA'),
    ('2024-07-01', N'Canada Day',                                   'CA'),
    ('2024-09-02', N'Labour Day',                                   'CA'),
    ('2024-09-30', N'National Day for Truth and Reconciliation',    'CA'),
    ('2024-10-14', N'Thanksgiving',                                 'CA'),
    ('2024-11-11', N'Remembrance Day',                              'CA'),
    ('2024-12-25', N'Christmas Day',                                'CA'),
    ('2024-12-26', N'Boxing Day',                                   'CA'),
    -- 2025 national
    ('2025-01-01', N'New Year''s Day',                              'CA'),
    ('2025-04-18', N'Good Friday',                                  'CA'),
    ('2025-07-01', N'Canada Day',                                   'CA'),
    ('2025-09-01', N'Labour Day',                                   'CA'),
    ('2025-09-30', N'National Day for Truth and Reconciliation',    'CA'),
    ('2025-10-13', N'Thanksgiving',                                 'CA'),
    ('2025-11-11', N'Remembrance Day',                              'CA'),
    ('2025-12-25', N'Christmas Day',                                'CA'),
    ('2025-12-26', N'Boxing Day',                                   'CA'),
    -- Ontario
    ('2024-02-19', N'Family Day',                                   'ON'),
    ('2024-05-20', N'Victoria Day',                                 'ON'),
    ('2024-08-05', N'Civic Holiday',                                'ON'),
    ('2025-02-17', N'Family Day',                                   'ON'),
    ('2025-05-19', N'Victoria Day',                                 'ON'),
    ('2025-08-04', N'Civic Holiday',                                'ON'),
    -- British Columbia
    ('2024-02-19', N'Family Day',                                   'BC'),
    ('2024-05-20', N'Victoria Day',                                 'BC'),
    ('2024-08-05', N'British Columbia Day',                         'BC'),
    ('2025-02-17', N'Family Day',                                   'BC'),
    ('2025-05-19', N'Victoria Day',                                 'BC'),
    ('2025-08-04', N'British Columbia Day',                         'BC'),
    -- Quebec
    ('2024-05-20', N'National Patriots'' Day',                      'QC'),
    ('2024-06-24', N'Saint-Jean-Baptiste Day',                      'QC'),
    ('2025-05-19', N'National Patriots'' Day',                      'QC'),
    ('2025-06-24', N'Saint-Jean-Baptiste Day',                      'QC'),
    -- Alberta
    ('2024-02-19', N'Family Day',                                   'AB'),
    ('2024-05-20', N'Victoria Day',                                 'AB'),
    ('2024-08-05', N'Heritage Day',                                 'AB'),
    ('2025-02-17', N'Family Day',                                   'AB'),
    ('2025-05-19', N'Victoria Day',                                 'AB'),
    ('2025-08-04', N'Heritage Day',                                 'AB')
) AS src (HolidayDate, HolidayName, JurisdictionCode)
    ON tgt.HolidayDate = src.HolidayDate AND tgt.JurisdictionCode = src.JurisdictionCode
WHEN MATCHED THEN
    UPDATE SET HolidayName = src.HolidayName
WHEN NOT MATCHED BY TARGET THEN
    INSERT (HolidayDate, HolidayName, JurisdictionCode)
    VALUES (src.HolidayDate, src.HolidayName, src.JurisdictionCode);
GO

PRINT '020 reference data seeded.';
GO
