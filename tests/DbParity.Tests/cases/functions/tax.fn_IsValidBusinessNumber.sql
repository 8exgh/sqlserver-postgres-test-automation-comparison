-- @name      tax.fn_IsValidBusinessNumber · bare and full BN forms
-- @category  function-scalar
SELECT v.BN, tax.fn_IsValidBusinessNumber(v.BN) AS IsValid
FROM (VALUES ('123456789'), ('123456789RT0001'), ('123456789XX0001'),
             ('12345678'), ('123456789RT'), ('')) AS v(BN)
ORDER BY v.BN;
