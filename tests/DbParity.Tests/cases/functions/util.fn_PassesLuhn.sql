-- @name      util.fn_PassesLuhn · mod-10 check
-- @category  function-scalar
--
-- Valid and invalid payloads either side of the check digit, plus the
-- short-input and NULL guards.
SELECT v.Digits, util.fn_PassesLuhn(v.Digits) AS Passes
FROM (VALUES ('79135791'), ('791357916'), ('791357917'), ('046454286'),
             ('4'), (''), ('12345678903'), ('12345678904')) AS v(Digits)
ORDER BY v.Digits;
