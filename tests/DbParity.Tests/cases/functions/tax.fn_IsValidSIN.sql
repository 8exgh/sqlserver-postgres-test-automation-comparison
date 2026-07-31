-- @name      tax.fn_IsValidSIN · nine digits plus Luhn
-- @category  function-scalar
--
-- Includes the SINs actually seeded, so a change to the check-digit logic shows
-- up against real fixture data and not only against synthetic input.
SELECT v.SIN, tax.fn_IsValidSIN(v.SIN) AS IsValid
FROM (VALUES ('791357916'), ('791357917'), ('12345678'), ('1234567890'),
             ('abcdefghi'), ('000000000')) AS v(SIN)
ORDER BY v.SIN;
