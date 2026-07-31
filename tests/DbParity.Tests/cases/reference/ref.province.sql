-- @name      ref.province · full contents
-- @category  reference-data
-- @table     ref.province
--
-- ref.* is seeded independently on each engine from its own
-- 020_seed_reference_data.sql, so this compares the two ports of that seed
-- rather than data one side copied from the other. Ordered by the natural key:
-- the surrogate identity values are assigned in seed order and differ.
SELECT *
FROM ref.province
ORDER BY ProvinceCode;
