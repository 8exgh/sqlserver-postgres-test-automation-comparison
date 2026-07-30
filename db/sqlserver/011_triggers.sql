/*==============================================================================
  011 - Triggers

    acct.tr_JournalLine_NoPostedEdits   AFTER  UPDATE, DELETE  - immutability
    client.tr_Client_Audit              AFTER  INSERT/UPDATE/DELETE - audit log
    tax.tr_T1Return_StatusHistory       AFTER  UPDATE          - status trail
    client.tr_ClientDirectory_Insert    INSTEAD OF INSERT      - on a view

  Additional error numbers raised here:

    50007  attempt to modify a line of a posted journal entry
    50008  client directory insert missing a required field
==============================================================================*/
USE CdnTaxPractice;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/*==============================================================================
  acct.tr_JournalLine_NoPostedEdits

  Once an entry is posted its lines are immutable; a correction has to be made
  by a reversing entry. INSERT is deliberately not covered, because
  acct.usp_PostJournalEntry creates the entry as posted and then inserts its
  lines - guarding inserts too would make posting impossible.

  Note the consequence for deletes: because cascading deletes fire this
  trigger, a client that carries posted entries cannot be deleted. That is the
  intended reading of "the books are immutable", not an oversight.
==============================================================================*/
CREATE OR ALTER TRIGGER acct.tr_JournalLine_NoPostedEdits
ON acct.JournalLine
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM deleted)
        RETURN;

    IF EXISTS (SELECT 1
               FROM   deleted             AS d
               JOIN   acct.JournalEntry   AS e ON e.JournalEntryId = d.JournalEntryId
               WHERE  e.IsPosted = 1)
    BEGIN
        THROW 50007,
              'Lines of a posted journal entry cannot be changed or deleted; post a reversing entry instead.',
              1;
    END
END
GO

/*==============================================================================
  client.tr_Client_Audit

  Writes a before/after image of every affected row to audit.ChangeLog.

  The row images are serialized with FOR JSON PATH, WITHOUT_ARRAY_WRAPPER so
  each payload is a JSON *object* rather than a single-element array - that is
  what lets audit.vw_RecentChanges use OPENJSON's [key] as the column name.

  The FULL OUTER JOIN between inserted and deleted is what makes one trigger
  body cover all three operations: rows present only in inserted are inserts,
  only in deleted are deletes, and in both are updates.
==============================================================================*/
CREATE OR ALTER TRIGGER client.tr_Client_Audit
ON client.Client
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted)
        RETURN;

    INSERT INTO audit.ChangeLog
        (SchemaName, TableName, PrimaryKeyValue, Operation, OldValues, NewValues)
    SELECT N'client',
           N'Client',
           CONVERT(NVARCHAR(100), COALESCE(i.ClientId, d.ClientId)),
           CASE WHEN i.ClientId IS NOT NULL AND d.ClientId IS NOT NULL THEN 'U'
                WHEN i.ClientId IS NOT NULL                            THEN 'I'
                ELSE                                                        'D'
           END,
           (
               SELECT dd.ClientId, dd.ClientCode, dd.ClientType, dd.DisplayName,
                      dd.FirstName, dd.LastName, dd.LegalName, dd.SIN,
                      dd.BusinessNumber, dd.ProvinceCode, dd.MaritalStatus,
                      dd.IsActive, dd.OnboardedDate
               FROM   deleted AS dd
               WHERE  dd.ClientId = d.ClientId
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
           ),
           (
               SELECT ii.ClientId, ii.ClientCode, ii.ClientType, ii.DisplayName,
                      ii.FirstName, ii.LastName, ii.LegalName, ii.SIN,
                      ii.BusinessNumber, ii.ProvinceCode, ii.MaritalStatus,
                      ii.IsActive, ii.OnboardedDate
               FROM   inserted AS ii
               WHERE  ii.ClientId = i.ClientId
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
           )
    FROM   inserted AS i
    FULL   OUTER JOIN deleted AS d ON d.ClientId = i.ClientId;
END
GO

/*==============================================================================
  tax.tr_T1Return_StatusHistory

  Records filing-status transitions. UPDATE(FilingStatus) is a cheap early
  exit: it is true when the column appeared in the UPDATE's SET list, whether
  or not the value actually differs - so the row comparison below is still
  required to avoid logging no-op writes.
==============================================================================*/
CREATE OR ALTER TRIGGER tax.tr_T1Return_StatusHistory
ON tax.T1Return
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT UPDATE(FilingStatus)
        RETURN;

    INSERT INTO audit.ReturnStatusHistory (T1ReturnId, OldStatus, NewStatus)
    SELECT i.T1ReturnId, d.FilingStatus, i.FilingStatus
    FROM   inserted AS i
    JOIN   deleted  AS d ON d.T1ReturnId = i.T1ReturnId
    WHERE  i.FilingStatus <> d.FilingStatus;
END
GO

/*==============================================================================
  client.tr_ClientDirectory_Insert  (INSTEAD OF INSERT on a view)

  client.vw_ClientDirectory spans three tables and so is not insertable on its
  own. This trigger makes it behave as though it were, fanning a single row out
  into the client, its primary address and its primary email.

  MERGE ... ON 1 = 0 is the idiom for "insert everything, and give me back the
  generated key paired with a source column" - a plain INSERT ... OUTPUT cannot
  emit columns from the source, so there would be no way to match the new
  ClientIds back to their rows.
==============================================================================*/
CREATE OR ALTER TRIGGER client.tr_ClientDirectory_Insert
ON client.vw_ClientDirectory
INSTEAD OF INSERT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted)
        RETURN;

    IF EXISTS (SELECT 1 FROM inserted
               WHERE ClientCode IS NULL OR ClientType IS NULL OR ProvinceCode IS NULL)
        THROW 50008,
              'ClientCode, ClientType and ProvinceCode are required when inserting through client.vw_ClientDirectory.',
              1;

    DECLARE @map TABLE
    (
        ClientId   INT          NOT NULL,
        ClientCode NVARCHAR(20) NOT NULL PRIMARY KEY
    );

    MERGE client.Client AS tgt
    USING inserted      AS src
          ON 1 = 0                      -- never matches: every source row inserts
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (ClientCode, ClientType, FirstName, LastName, DateOfBirth, SIN,
                LegalName, IncorporationDate, BusinessNumber, FiscalYearEndMonth,
                ProvinceCode, OnboardedDate, IsActive)
        VALUES (src.ClientCode,
                src.ClientType,
                src.FirstName,
                src.LastName,
                -- The view does not expose these, so individuals inserted this
                -- way get placeholders that satisfy CK_Client_TypeShape.
                CASE WHEN src.ClientType = 'I' THEN '1900-01-01' END,
                src.SIN,
                src.LegalName,
                CASE WHEN src.ClientType = 'C' THEN '1900-01-01' END,
                src.BusinessNumber,
                CASE WHEN src.ClientType = 'C' THEN 12 END,
                src.ProvinceCode,
                ISNULL(src.OnboardedDate, CONVERT(DATE, SYSUTCDATETIME())),
                ISNULL(src.IsActive, 1))
    OUTPUT inserted.ClientId, inserted.ClientCode INTO @map (ClientId, ClientCode);

    INSERT INTO client.ClientAddress
        (ClientId, AddressType, Line1, Line2, City, ProvinceCode, PostalCode, IsPrimary)
    SELECT m.ClientId, N'Mailing', i.Line1, i.Line2, i.City, i.ProvinceCode, i.PostalCode, 1
    FROM   inserted AS i
    JOIN   @map     AS m ON m.ClientCode = i.ClientCode
    WHERE  i.Line1      IS NOT NULL
      AND  i.City       IS NOT NULL
      AND  i.PostalCode IS NOT NULL;

    INSERT INTO client.ClientContact (ClientId, ContactType, ContactValue, IsPrimary)
    SELECT m.ClientId, N'Email', i.PrimaryEmail, 1
    FROM   inserted AS i
    JOIN   @map     AS m ON m.ClientCode = i.ClientCode
    WHERE  i.PrimaryEmail IS NOT NULL;
END
GO

PRINT '011 triggers ready.';
GO
