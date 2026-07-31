-- @name      tax.vw_ClientTaxProfile · full contents
-- @category  view-temporal
--
-- The widest cross-schema roll-up, and "as at today" per db/README.md.
SELECT *
FROM tax.vw_ClientTaxProfile
ORDER BY ClientId;
