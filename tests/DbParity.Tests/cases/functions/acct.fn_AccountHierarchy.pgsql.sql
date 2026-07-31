SELECT c.ClientId, h.AccountId, h.ParentAccountId, h.AccountNumber, h.AccountName,
       h.AccountTypeCode, h.Depth, h.NamePath, h.SortPath
FROM client.Client c
     CROSS JOIN LATERAL acct.fn_AccountHierarchy(c.ClientId, NULL) h
ORDER BY c.ClientId, h.SortPath, h.AccountId;
