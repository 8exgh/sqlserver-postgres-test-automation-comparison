-- @name      tax.fn_IsValidSIN · every seeded SIN
-- @category  function-scalar
--
-- Every SIN in the fixture must pass; db/README.md states they are synthetic
-- values chosen to satisfy the mod-10 check.
SELECT c.ClientId, c.SIN, tax.fn_IsValidSIN(c.SIN) AS IsValid
FROM client.Client c
WHERE c.SIN IS NOT NULL
ORDER BY c.ClientId;
