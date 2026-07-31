-- @name      acct.fn_AccountBalance · every account, signed by normal balance
-- @category  function-accounting
--
-- Covers all 63 seeded accounts. The sign depends on the account's normal
-- balance, which is the part most easily lost in translation.
SELECT a.AccountId, a.AccountNumber, v.AsOf,
       acct.fn_AccountBalance(a.AccountId, v.AsOf) AS Balance
FROM acct.Account a
CROSS JOIN (VALUES (CAST('2023-12-31' AS DATE)), (CAST('2024-12-31' AS DATE)),
                   (CAST('2025-12-31' AS DATE))) AS v(AsOf)
ORDER BY a.AccountId, v.AsOf;
