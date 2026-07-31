-- @name      acct.journalentry · full contents
-- @category  sample-data
-- @table     acct.journalentry
--
-- Replicated from SQL Server by scripts/replicate-to-postgres.sh, so the input
-- is identical by construction and any difference here is the port's doing --
-- most usefully in the generated columns, which PostgreSQL recomputes because
-- a GENERATED ALWAYS ... STORED column cannot be written to.
SELECT *
FROM acct.journalentry
ORDER BY JournalEntryId;
