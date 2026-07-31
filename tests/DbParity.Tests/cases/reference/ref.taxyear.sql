-- @name      ref.taxyear · full contents
-- @category  reference-data
-- @table     ref.taxyear
--
-- Independently seeded on each engine from its own 020_seed_reference_data.sql,
-- with one column the replicator carries across: IsLocked.
-- db/sqlserver/021_seed_sample_data.sql locks the 2023 tax year at the very end
-- of the sample seed, and PostgreSQL never runs that script -- so without the
-- sync, 2023 stays unlocked there and tax.usp_CalculateT1 never raises error
-- 50011. This case is what caught that.
SELECT *
FROM ref.taxyear
ORDER BY TaxYear;
