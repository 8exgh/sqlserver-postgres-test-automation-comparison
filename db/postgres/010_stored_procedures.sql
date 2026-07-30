/*==============================================================================
  010 - Stored procedures  (PostgreSQL)

  Port of db/sqlserver/010_stored_procedures.sql - all twelve procedures.

  ---------------------------------------------------------------------------
  TRANSACTION CONTROL

  The SQL Server originals open and commit their own transactions and inspect
  @@TRANCOUNT. AWS SCT commented all of that out as CRITICAL (action items
  7615, 7674, 7807, 7811) and left the bodies running with no transaction
  semantics at all.

  None of it is reinstated, because PostgreSQL does not need it: a PL/pgSQL
  block that has an EXCEPTION handler is itself a subtransaction. If any
  statement inside fails, everything the block did is rolled back and the
  handler runs - which is exactly what BEGIN TRAN / ROLLBACK bought in T-SQL.
  The procedures therefore remain atomic within the caller's transaction, and
  SAVE TRANSACTION in usp_PostJournalEntry is covered by the same mechanism
  when usp_CloseFiscalYear calls it.

  ---------------------------------------------------------------------------
  WHAT WAS ACTUALLY REWRITTEN

    MERGE           usp_UpsertClient, usp_RunPayroll, usp_ImportSlips.
                    SCT emitted "Transformer error occurred in mergeStatement"
                    and commented the statement out, leaving procedures that
                    silently did nothing. PostgreSQL 15+ has MERGE.

    OUTPUT $action  MERGE ... RETURNING and merge_action() are PostgreSQL 17;
                    this targets 16, so the affected rows are identified by
                    natural key instead.

    OPENJSON        usp_ImportSlips - jsonb_to_recordset, with double-quoted
                    column names so they match the camelCase JSON keys.

    ISJSON          usp_ImportSlips - pg_input_is_valid(x, 'jsonb').

    DELETE TOP (n)  usp_PurgeChangeLog - DELETE ... WHERE ctid IN (... LIMIT n).

    sp_executesql   usp_SearchClients - EXECUTE ... USING with numbered
                    placeholders. SCT left the T-SQL string verbatim.

  Result sets are returned through INOUT refcursor parameters, which is SCT's
  choice and the normal PostgreSQL idiom.

  Error numbers travel as SQLSTATE: THROW 50001 -> ERRCODE '50001', so the same
  assertion works against both engines.

  SMALLINT parameters (TaxYear, FiscalYearEndMonth) are widened to INTEGER for
  the same reason as in 008: PostgreSQL will not implicitly narrow an integer
  literal during procedure resolution, so CALL ... (par_taxyear := 2024) would
  not resolve at all.
==============================================================================*/

SET client_min_messages = warning;

/*------------------------------------------------------------------------------
  CREATE OR REPLACE keeps an old overload alive when a signature changes, and
  the next call then fails with 42725 (ambiguous). Dropping by name first
  makes re-applying this file clean.
------------------------------------------------------------------------------*/
DROP PROCEDURE IF EXISTS acct.usp_closefiscalyear CASCADE;
DROP PROCEDURE IF EXISTS acct.usp_generateinvoice CASCADE;
DROP PROCEDURE IF EXISTS acct.usp_postjournalentry CASCADE;
DROP PROCEDURE IF EXISTS audit.usp_purgechangelog CASCADE;
DROP PROCEDURE IF EXISTS client.usp_searchclients CASCADE;
DROP PROCEDURE IF EXISTS client.usp_upsertclient CASCADE;
DROP PROCEDURE IF EXISTS payroll.usp_runpayroll CASCADE;
DROP PROCEDURE IF EXISTS tax.usp_calculatet1 CASCADE;
DROP PROCEDURE IF EXISTS tax.usp_filegsthstreturn CASCADE;
DROP PROCEDURE IF EXISTS tax.usp_generateclientyearendpackage CASCADE;
DROP PROCEDURE IF EXISTS tax.usp_importslips CASCADE;
DROP PROCEDURE IF EXISTS tax.usp_recalculateallreturns CASCADE;

CREATE OR REPLACE PROCEDURE acct.usp_closefiscalyear(IN par_clientid INTEGER, IN par_fiscalyearid INTEGER, IN par_retainedearningsaccountnumber VARCHAR DEFAULT '3200', IN par_postedby VARCHAR DEFAULT NULL, INOUT p_refcur refcursor DEFAULT NULL)
AS 
$BODY$
/*
==============================================================================
  acct.usp_CloseFiscalYear

  Closes every nominal (revenue and expense) account into retained earnings.

  Written with an explicit cursor. A set-based equivalent is possible and would
  be faster - the closing lines are just a SELECT over acct.fn_TrialBalance,
  which is how the retained-earnings balancing line below is in fact built. The
  cursor is kept because walking accounts one at a time is what the equivalent
  procedure looks like in most real ledgers, and it gives the schema a genuine
  cursor to exercise.
==============================================================================
*/
DECLARE
    var_endDate DATE;
    var_isClosed NUMERIC(1, 0);
    var_lineNumber INTEGER DEFAULT 0;
    var_netIncome NUMERIC(19, 2) DEFAULT 0;
    var_accountNumber VARCHAR(20);
    var_accountName VARCHAR(100);
    var_normalBalance CHAR(1);
    var_balance NUMERIC(19, 2);
    nominal_cursor CURSOR FOR
    SELECT
        tb.accountnumber, tb.accountname, tb.normalbalance, tb.balance
        FROM acct.fn_trialbalance(par_ClientId, par_FiscalYearId, var_endDate)
            AS tb
        JOIN ref.accounttype AS t
            ON LOWER(t.accounttypecode) = LOWER(tb.accounttypecode)
        WHERE tb.istotalrow = 0 AND t.isnominal = 1 AND tb.balance <> 0
        ORDER BY tb.accountnumber NULLS FIRST;
    var_journalEntryId INTEGER;
    var_closingLines acct.journallinetype[] DEFAULT '{}';
BEGIN
    par_PostedBy := COALESCE(par_PostedBy, CURRENT_USER);
    SELECT
        fy.enddate, (CASE WHEN fy.isclosed = 1 THEN 1 ELSE 0 END)
        INTO var_endDate, var_isClosed
        FROM acct.fiscalyear AS fy
        WHERE fy.fiscalyearid = par_FiscalYearId AND fy.clientid = par_ClientId;

    IF var_endDate IS NULL THEN
        RAISE 'Fiscal year not found for this client.' USING ERRCODE := '50005';
    END IF;

    IF var_isClosed = 1 THEN
        RAISE 'The fiscal year is already closed.' USING ERRCODE := '50004';
    END IF;

    IF NOT EXISTS (SELECT
        1
        FROM acct.account
        WHERE clientid = par_ClientId AND LOWER(accountnumber) = LOWER(par_RetainedEarningsAccountNumber)) THEN
        RAISE 'The retained earnings account does not exist for this client.' USING ERRCODE := '50002';
    END IF;
    /* --- cursor over the nominal accounts carrying a balance ------------- */
    OPEN nominal_cursor;
    FETCH NEXT FROM nominal_cursor INTO var_accountNumber, var_accountName, var_normalBalance, var_balance;

    WHILE (CASE FOUND::INT
        WHEN 0 THEN - 1
        ELSE 0
    END) = 0 LOOP
        var_lineNumber := var_lineNumber + 1;
        /* Closing an account means posting the opposite of its balance. */

        IF LOWER(var_normalBalance) = LOWER('C') THEN
            /* Revenue: normally a credit balance, so debit it away. */
            var_closingLines := var_closingLines || ROW(var_lineNumber, var_accountNumber, var_balance, 0, CONCAT('Close ', var_accountName))::acct.journallinetype;
            var_netIncome := var_netIncome + var_balance;
        ELSE
            /* Expense: normally a debit balance, so credit it away. */
            var_closingLines := var_closingLines || ROW(var_lineNumber, var_accountNumber, 0, var_balance, CONCAT('Close ', var_accountName))::acct.journallinetype;
            var_netIncome := var_netIncome - var_balance;
        END IF;
        FETCH NEXT FROM nominal_cursor INTO var_accountNumber, var_accountName, var_normalBalance, var_balance;
    END LOOP;
    CLOSE nominal_cursor;

    IF var_lineNumber = 0 THEN
        RAISE 'There are no nominal account balances to close.' USING ERRCODE := '50006';
    END IF;
    /* --- the balancing line to retained earnings ------------------------ */
    var_lineNumber := var_lineNumber + 1;
    var_closingLines := var_closingLines || ROW(var_lineNumber, par_RetainedEarningsAccountNumber,
    CASE
        WHEN var_netIncome < 0 THEN - var_netIncome
        ELSE 0
    END,
    /* a loss debits equity */
    CASE
        WHEN var_netIncome > 0 THEN var_netIncome
        ELSE 0
    END,
    /* a profit credits it */
    'Net income transferred to retained earnings')::acct.journallinetype;

    BEGIN
        /* Nested call: usp_PostJournalEntry sees @@TRANCOUNT > 0 and takes a */
        /* savepoint instead of opening its own transaction. */
        CALL acct.usp_postjournalentry(par_ClientId := par_ClientId, par_FiscalYearId := par_FiscalYearId, par_EntryDate := var_endDate, par_Description := 'Year-end closing entry', par_Lines := var_closingLines, par_Source := 'YearEnd', par_PostedBy := par_PostedBy, par_JournalEntryId => var_journalEntryId);
        UPDATE acct.fiscalyear
        SET isclosed = 1, closedat = timezone('UTC', LOCALTIMESTAMP(6))
            WHERE fiscalyearid = par_FiscalYearId;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE;
    END;
    OPEN p_refcur FOR
    SELECT
        var_journalEntryId AS closingjournalentryid, var_lineNumber AS linesposted, var_netIncome AS netincomeclosed;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE acct.usp_generateinvoice(IN par_clientid INTEGER, IN par_invoicedate DATE, IN par_lines acct.invoicelinetype[], IN par_engagementid INTEGER DEFAULT NULL, IN par_paymentterms INTEGER DEFAULT 30, IN par_notes VARCHAR DEFAULT NULL, IN par_status VARCHAR DEFAULT 'Sent', INOUT par_invoiceid INTEGER DEFAULT NULL, INOUT p_refcur refcursor DEFAULT NULL)
AS 
$BODY$
/*
==============================================================================
  acct.usp_GenerateInvoice

  Allocates an invoice number from the sequence, then applies the sales tax
  rates in force in the client's province on the invoice date. GST/HST and PST
  are tracked separately because only the first is remitted to the CRA.
==============================================================================
*/
DECLARE
    var_provinceCode CHAR(2);
    var_gstHstRate NUMERIC(9, 5);
    var_pstRate NUMERIC(9, 5);
    var_subtotal NUMERIC(19, 2);
    var_taxableAmount NUMERIC(19, 2);
    var_gstHstAmount NUMERIC(19, 2);
    var_pstAmount NUMERIC(19, 2);
    var_invoiceNumber INTEGER DEFAULT nextval('acct.seq_invoicenumber');
BEGIN

    IF NOT EXISTS (SELECT
        1
        FROM UNNEST(par_Lines)) THEN
        RAISE 'An invoice must have at least one line.' USING ERRCODE := '50050';
    END IF;
    SELECT
        c.provincecode
        INTO var_provinceCode
        FROM client.client AS c
        WHERE c.clientid = par_ClientId;

    IF var_provinceCode IS NULL THEN
        RAISE 'Unknown client.' USING ERRCODE := '50021';
    END IF;

        -- Assigned here rather than as a DECLARE default: PL/pgSQL evaluates
        -- DECLARE defaults on block entry, before the lookups below have run,
        -- so AWS SCT's version computed these from NULLs.
        var_gstHstRate := ref.fn_gsthstrate(var_provinceCode, par_InvoiceDate);
        var_pstRate    := ref.fn_pstrate(var_provinceCode, par_InvoiceDate);
    SELECT
        SUM(CAST (ROUND(l.quantity * l.unitprice, 2) AS NUMERIC(19, 2))), SUM(CASE
            WHEN l.istaxable = 1 THEN CAST (ROUND(l.quantity * l.unitprice, 2) AS NUMERIC(19, 2))
            ELSE 0
        END)
        INTO var_subtotal, var_taxableAmount
        FROM UNNEST(par_Lines) AS l;

        var_gstHstAmount := CAST(ROUND(var_taxableAmount * var_gstHstRate, 2) AS NUMERIC(19, 2));
        var_pstAmount    := CAST(ROUND(var_taxableAmount * var_pstRate,    2) AS NUMERIC(19, 2));

    BEGIN
        /* Writes begin here; see the note at the top of this file. */
        
        
        -- AWS SCT stages every RETURNING value through a temp table and then
        -- opens the result cursor over it. Two problems: the cursor keeps the
        -- table open, so the next call in the same session cannot drop it
        -- ("cannot DROP TABLE ... because it is being used by active queries");
        -- and the table is only dropped in the exception handler, so it
        -- survives a successful call. RETURNING ... INTO a variable does the
        -- same job with nothing to clean up.
        INSERT INTO acct.invoice (invoicenumber, clientid, engagementid, invoicedate, duedate, provincecode, subtotal, gsthstamount, pstamount, status, notes)
        VALUES (var_invoiceNumber, par_ClientId, par_EngagementId, par_InvoiceDate, par_InvoiceDate + (par_PaymentTerms::NUMERIC || ' DAY')::INTERVAL, var_provinceCode, var_subtotal, var_gstHstAmount, var_pstAmount, par_Status, par_Notes)
        RETURNING invoiceid, invoicenumber INTO par_InvoiceId, var_invoiceNumber;
        INSERT INTO acct.invoiceline (invoiceid, linenumber, description, quantity, unitprice, istaxable)
        SELECT
            par_InvoiceId, l.linenumber, l.description, l.quantity, l.unitprice, l.istaxable
            FROM UNNEST(par_Lines) AS l;
        OPEN p_refcur FOR
        SELECT
            par_InvoiceId AS invoiceid, var_invoiceNumber AS invoicenumber, var_provinceCode AS provincecode, var_gstHstRate AS gsthstrate, var_pstRate AS pstrate, var_subtotal AS subtotal, var_gstHstAmount AS gsthstamount, var_pstAmount AS pstamount, var_subtotal + var_gstHstAmount + var_pstAmount AS total;

        EXCEPTION
            WHEN OTHERS THEN
                RAISE;
    END;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE acct.usp_postjournalentry(IN par_clientid INTEGER, IN par_fiscalyearid INTEGER, IN par_entrydate DATE, IN par_description VARCHAR, IN par_lines acct.journallinetype[], IN par_source VARCHAR DEFAULT 'Manual', IN par_postedby VARCHAR DEFAULT NULL, IN par_postimmediately NUMERIC DEFAULT 1, INOUT par_journalentryid INTEGER DEFAULT NULL, INOUT p_refcur refcursor DEFAULT NULL)
AS 
$BODY$
/*
==============================================================================
  acct.usp_PostJournalEntry

  Takes its lines as a table-valued parameter. Every validation runs before the
  transaction opens, so the THROWs cannot doom a transaction and the savepoint
  below stays usable when this is called from inside another procedure's
  transaction (which acct.usp_CloseFiscalYear does).
==============================================================================
*/
DECLARE
    var_debits NUMERIC(19, 2);
    var_credits NUMERIC(19, 2);
    -- Built in the body: as a DECLARE default it would be evaluated on block
    -- entry, with both totals still NULL, so the error text lost its numbers.
    var_msg VARCHAR(200);
    -- Declared inside the T-SQL transaction block, which AWS SCT commented out
    -- wholesale - taking this declaration with it.
    var_entryNumber INTEGER;
    -- Retained only as documentation of the original control flow: PostgreSQL
    -- needs no savepoint here because the BEGIN ... EXCEPTION block below is
    -- itself a subtransaction, whether or not a caller already has one open.
    var_ownsTransaction NUMERIC(1, 0) DEFAULT 0;
BEGIN
    -- AWS SCT dropped "SET @PostedBy = ISNULL(@PostedBy, SUSER_SNAME())"
    -- entirely. Without it a caller that omits the argument leaves PostedBy
    -- NULL, which violates ck_journalentry_posted the moment the entry is
    -- posted. CURRENT_USER is the SUSER_SNAME() equivalent.
    par_PostedBy := COALESCE(par_PostedBy, CURRENT_USER);

    IF NOT EXISTS (SELECT
        1
        FROM UNNEST(par_Lines)) THEN
        RAISE 'A journal entry must have at least one line.' USING ERRCODE := '50006';
    END IF;
    SELECT
        SUM(l.debitamount), SUM(l.creditamount)
        INTO var_debits, var_credits
        FROM UNNEST(par_Lines) AS l;

    IF var_debits <> var_credits THEN
        var_msg := CONCAT('Journal entry does not balance: debits ', var_debits,
                          ' vs credits ', var_credits, '.');
        RAISE '%', var_msg USING ERRCODE := '50001';
    END IF;

    IF EXISTS (SELECT
        1
        FROM UNNEST(par_Lines) AS l
        WHERE NOT EXISTS (SELECT
            1
            FROM acct.account AS a
            WHERE a.clientid = par_ClientId AND LOWER(a.accountnumber) = LOWER(l.accountnumber))) THEN
        RAISE 'One or more account numbers do not exist for this client.' USING ERRCODE := '50002';
    END IF;

    IF EXISTS (SELECT
        1
        FROM UNNEST(par_Lines) AS l
        JOIN acct.account AS a
            ON a.clientid = par_ClientId AND LOWER(a.accountnumber) = LOWER(l.accountnumber)
        WHERE a.iscontrolaccount = 1) THEN
        RAISE 'Postings may not be made directly to a control account.' USING ERRCODE := '50003';
    END IF;

    IF EXISTS (SELECT
        1
        FROM acct.fiscalyear AS fy
        WHERE fy.fiscalyearid = par_FiscalYearId AND fy.isclosed = 1) THEN
        RAISE 'The fiscal year is closed and will not accept new entries.' USING ERRCODE := '50004';
    END IF;

    IF NOT EXISTS (SELECT
        1
        FROM acct.fiscalyear AS fy
        WHERE fy.fiscalyearid = par_FiscalYearId AND fy.clientid = par_ClientId AND par_EntryDate BETWEEN fy.startdate AND fy.enddate) THEN
        RAISE 'The entry date falls outside the given fiscal year.' USING ERRCODE := '50005';
    END IF;
    /* --- write --------------------------------------------------------- */
    /* A savepoint when already inside a caller's transaction, a transaction of */
    /* our own otherwise. Either way this procedure undoes only its own work. */
    BEGIN
        IF var_ownsTransaction = 1 THEN
            BEGIN
            END;
        ELSE
            BEGIN
            END;
        END IF;
        SELECT
            COALESCE(MAX(e.entrynumber), 0) + 1
            INTO var_entryNumber
            FROM acct.journalentry AS e
            WHERE e.clientid = par_ClientId;
        -- AWS SCT stages every RETURNING value through a temp table and then
        -- opens the result cursor over it. Two problems: the cursor keeps the
        -- table open, so the next call in the same session cannot drop it
        -- ("cannot DROP TABLE ... because it is being used by active queries");
        -- and the table is only dropped in the exception handler, so it
        -- survives a successful call. RETURNING ... INTO a variable does the
        -- same job with nothing to clean up.
        INSERT INTO acct.journalentry (clientid, fiscalyearid, entrynumber, entrydate, description, source, isposted, postedat, postedby)
        VALUES (par_ClientId, par_FiscalYearId, var_entryNumber, par_EntryDate, par_Description, par_Source, (CASE WHEN par_PostImmediately = 1 THEN 1 ELSE 0 END),
        CASE
            WHEN par_PostImmediately = 1 THEN timezone('UTC', LOCALTIMESTAMP(6))
        END,
        CASE
            WHEN par_PostImmediately = 1 THEN par_PostedBy
        END)
        RETURNING journalentryid INTO par_JournalEntryId;
        INSERT INTO acct.journalline (journalentryid, linenumber, accountid, debitamount, creditamount, memo)
        SELECT
            par_JournalEntryId, l.linenumber, a.accountid, l.debitamount, l.creditamount, l.memo
            FROM UNNEST(par_Lines) AS l
            JOIN acct.account AS a
                ON a.clientid = par_ClientId AND LOWER(a.accountnumber) = LOWER(l.accountnumber);

        OPEN p_refcur FOR
        SELECT
            par_JournalEntryId AS journalentryid, var_entryNumber AS entrynumber, var_debits AS totaldebits, var_credits AS totalcredits;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE;
    END;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE audit.usp_purgechangelog(IN par_retentiondays INTEGER DEFAULT 365, IN par_batchsize INTEGER DEFAULT 1000, IN par_maxbatches INTEGER DEFAULT 1000, INOUT par_rowsdeleted INTEGER DEFAULT NULL, INOUT p_refcur refcursor DEFAULT NULL)
AS 
$BODY$
/*
==============================================================================
  audit.usp_PurgeChangeLog

  Deletes in bounded batches rather than one statement, so a large purge does
  not hold a single long transaction or escalate to a table lock.
==============================================================================
*/
DECLARE
    -- Assigned in the body, not here: a DECLARE default is evaluated on block
    -- entry, before par_RetentionDays has been clamped below.
    var_cutoff TIMESTAMP(3) WITHOUT TIME ZONE;
    var_batchRows INTEGER DEFAULT 1;
    var_batchesRun INTEGER DEFAULT 0;
BEGIN
    IF par_RetentionDays < 0 THEN
        par_RetentionDays := 0;
    END IF;

    IF par_BatchSize < 1 OR par_BatchSize > 100000 THEN
        par_BatchSize := 1000;
    END IF;
    par_RowsDeleted := 0;
    var_cutoff := (timezone('UTC', LOCALTIMESTAMP(6)))::TIMESTAMP
                  + (- par_RetentionDays::NUMERIC || ' DAY')::INTERVAL;

    WHILE var_batchRows > 0 AND var_batchesRun < par_MaxBatches LOOP
        -- DELETE TOP (n) has no PostgreSQL equivalent (action item 7798).
        -- Selecting the batch by ctid with a LIMIT is the standard idiom and
        -- keeps the same bounded-batch behaviour.
        DELETE FROM audit.changelog
         WHERE ctid IN (SELECT ctid
                          FROM audit.changelog
                         WHERE changedat < var_cutoff
                         LIMIT par_BatchSize);
        GET DIAGNOSTICS var_batchRows = ROW_COUNT;
        par_RowsDeleted := par_RowsDeleted + var_batchRows;
        var_batchesRun := var_batchesRun + 1;
    END LOOP;
    OPEN p_refcur FOR
    SELECT
        par_RowsDeleted AS rowsdeleted, var_batchesRun AS batchesrun, var_cutoff AS cutoffutc;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE client.usp_searchclients(IN par_namecontains VARCHAR DEFAULT NULL, IN par_provincecode CHAR DEFAULT NULL, IN par_clienttype CHAR DEFAULT NULL, IN par_isactive NUMERIC DEFAULT NULL, IN par_onboardedfrom DATE DEFAULT NULL, IN par_sortcolumn VARCHAR DEFAULT 'DisplayName', IN par_sortdirection VARCHAR DEFAULT 'ASC', IN par_maxrows INTEGER DEFAULT 100, INOUT p_refcur refcursor DEFAULT NULL)
AS 
$BODY$
/*
==============================================================================
  client.usp_SearchClients

  Optional filters built into a dynamic statement. The predicate text is
  assembled from constants only; every user value travels as a parameter to
  sp_executesql, and the sort column is resolved against a whitelist, so no
  caller input is ever concatenated into the SQL.
==============================================================================
*/
DECLARE
    var_orderBy VARCHAR(200) DEFAULT
    CASE par_SortColumn
        WHEN 'DisplayName' THEN 'c.DisplayName'
        WHEN 'ClientCode' THEN 'c.ClientCode'
        WHEN 'OnboardedDate' THEN 'c.OnboardedDate'
        WHEN 'ProvinceCode' THEN 'c.ProvinceCode'
        ELSE 'c.DisplayName'
    END ||
    CASE
        WHEN LOWER(par_SortDirection) = LOWER('DESC') THEN ' DESC'
        ELSE ' ASC'
    END;
    -- Rebuilt for PostgreSQL: numbered placeholders instead of @named ones,
    -- LIMIT instead of TOP, and the parameters are passed with EXECUTE ...
    -- USING. AWS SCT left the T-SQL string untouched (action item 7672), so
    -- the procedure would have built a statement no PostgreSQL parser accepts.
    var_sql TEXT DEFAULT '
        SELECT c.clientid, c.clientcode, c.clienttype, c.displayname,
               c.provincecode, c.isactive, c.onboardeddate
        FROM   client.client AS c
        WHERE  1 = 1';
BEGIN
    /* Whitelist: anything unrecognised falls back to the default ordering. */
    IF par_NameContains IS NOT NULL THEN
        var_sql := var_sql || ' AND c.displayname LIKE ''%'' || $1 || ''%''';
    END IF;

    IF par_ProvinceCode IS NOT NULL THEN
        var_sql := var_sql || ' AND c.provincecode = $2';
    END IF;

    IF par_ClientType IS NOT NULL THEN
        var_sql := var_sql || ' AND c.clienttype = $3';
    END IF;

    IF par_IsActive IS NOT NULL THEN
        var_sql := var_sql || ' AND c.isactive = $4';
    END IF;

    IF par_OnboardedFrom IS NOT NULL THEN
        var_sql := var_sql || ' AND c.onboardeddate >= $5';
    END IF;
    -- var_orderBy comes from a CASE over a fixed set of literals, so nothing
    -- the caller supplies is ever concatenated into the statement. Every user
    -- value travels as a bound parameter.
    var_sql := var_sql || ' ORDER BY ' || var_orderBy || ' LIMIT $6';

    OPEN p_refcur FOR EXECUTE var_sql
        USING par_NameContains, par_ProvinceCode, par_ClientType,
              par_IsActive, par_OnboardedFrom, par_MaxRows;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE client.usp_upsertclient(IN par_clientcode VARCHAR, IN par_clienttype CHAR, IN par_provincecode CHAR, IN par_onboardeddate DATE DEFAULT NULL, IN par_firstname VARCHAR DEFAULT NULL, IN par_lastname VARCHAR DEFAULT NULL, IN par_dateofbirth DATE DEFAULT NULL, IN par_sin CHAR DEFAULT NULL, IN par_maritalstatus VARCHAR DEFAULT NULL, IN par_legalname VARCHAR DEFAULT NULL, IN par_incorporationdate DATE DEFAULT NULL, IN par_businessnumber CHAR DEFAULT NULL, IN par_fiscalyearendmonth INTEGER DEFAULT NULL, IN par_isactive NUMERIC DEFAULT 1, INOUT par_clientid INTEGER DEFAULT NULL, INOUT p_refcur refcursor DEFAULT NULL)
AS 
$BODY$
DECLARE
    var_existingid INTEGER;
    var_action     VARCHAR(10);
/*
==============================================================================
  client.usp_UpsertClient

  MERGE-based insert-or-update keyed on the natural key (ClientCode), with the
  identifier validators applied before anything is written.
==============================================================================
*/
/* individuals */
/* corporations */
BEGIN
    par_OnboardedDate := COALESCE(par_OnboardedDate, ((timezone('UTC', LOCALTIMESTAMP(6)))::date));

    BEGIN
        /* --- validation before any write -------------------------------- */
        IF LOWER(par_ClientType) NOT IN (LOWER('I'), LOWER('C')) THEN
            RAISE 'ClientType must be I (individual) or C (corporation).' USING ERRCODE := '50042';
        END IF;

        IF LOWER(par_ClientType) = LOWER('I') AND (par_FirstName IS NULL OR par_LastName IS NULL OR par_DateOfBirth IS NULL) THEN
            RAISE 'An individual client requires FirstName, LastName and DateOfBirth.' USING ERRCODE := '50042';
        END IF;

        IF LOWER(par_ClientType) = LOWER('C') AND (par_LegalName IS NULL OR par_IncorporationDate IS NULL OR par_FiscalYearEndMonth IS NULL) THEN
            RAISE 'A corporate client requires LegalName, IncorporationDate and FiscalYearEndMonth.' USING ERRCODE := '50042';
        END IF;

        IF par_SIN IS NOT NULL AND tax.fn_isvalidsin(par_SIN) = 0 THEN
            RAISE 'SIN failed the mod-10 check digit test.' USING ERRCODE := '50040';
        END IF;

        -- Same bad cast AWS SCT applied inside tax.fn_IsValidSIN: it converts
        -- the identifier to a number before handing it to a function that takes
        -- a VARCHAR. The call does not resolve, and a numeric conversion would
        -- also strip any leading zero and break the check digit.
        IF par_BusinessNumber IS NOT NULL AND tax.fn_isvalidbusinessnumber(par_BusinessNumber::VARCHAR) = 0 THEN
            RAISE 'Business Number failed the mod-10 check digit test.' USING ERRCODE := '50041';
        END IF;
        /* Null out the fields that do not apply, so the caller cannot smuggle */
        /* corporate values onto an individual and trip CK_Client_TypeShape. */

        IF LOWER(par_ClientType) = LOWER('I') THEN
            par_LegalName := NULL;
            par_IncorporationDate := NULL;
            par_BusinessNumber := NULL;
            par_FiscalYearEndMonth := NULL;
        ELSE
            par_FirstName := NULL;
            par_LastName := NULL;
            par_DateOfBirth := NULL;
            par_SIN := NULL;
            par_MaritalStatus := NULL;
        END IF;
        /* Writes begin here; see the note at the top of this file. */
        
        
        
        -- MERGE, which AWS SCT could not translate at all (action item 9996).
        -- PostgreSQL 15+ supports it directly; the statement below is the same
        -- shape as the T-SQL original.
        --
        -- The one thing that cannot be carried over verbatim is OUTPUT $action:
        -- MERGE ... RETURNING (and merge_action()) arrived in PostgreSQL 17 and
        -- this targets 16. Looking the row up first tells us which action the
        -- MERGE is about to take, which is the same information.
        SELECT c.clientid INTO var_existingid
          FROM client.client AS c
         WHERE c.clientcode = par_ClientCode;

        MERGE INTO client.client AS tgt
        USING (SELECT par_ClientCode AS clientcode) AS src
           ON tgt.clientcode = src.clientcode
        WHEN MATCHED THEN
            UPDATE SET clienttype         = par_ClientType,
                       firstname          = par_FirstName,
                       lastname           = par_LastName,
                       dateofbirth        = par_DateOfBirth,
                       sin                = par_SIN,
                       maritalstatus      = par_MaritalStatus,
                       legalname          = par_LegalName,
                       incorporationdate  = par_IncorporationDate,
                       businessnumber     = par_BusinessNumber,
                       fiscalyearendmonth = par_FiscalYearEndMonth,
                       provincecode       = par_ProvinceCode,
                       isactive           = par_IsActive,
                       updatedat          = timezone('UTC', LOCALTIMESTAMP(6))
        WHEN NOT MATCHED THEN
            INSERT (clientcode, clienttype, firstname, lastname, dateofbirth, sin,
                    maritalstatus, legalname, incorporationdate, businessnumber,
                    fiscalyearendmonth, provincecode, onboardeddate, isactive)
            VALUES (par_ClientCode, par_ClientType, par_FirstName, par_LastName,
                    par_DateOfBirth, par_SIN, par_MaritalStatus, par_LegalName,
                    par_IncorporationDate, par_BusinessNumber, par_FiscalYearEndMonth,
                    par_ProvinceCode, par_OnboardedDate, par_IsActive);

        SELECT c.clientid INTO par_ClientId
          FROM client.client AS c
         WHERE c.clientcode = par_ClientCode;

        var_action := CASE WHEN var_existingid IS NULL THEN 'INSERT' ELSE 'UPDATE' END;

        OPEN p_refcur FOR
        SELECT par_ClientId AS clientid, var_action AS mergeaction;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE;
    END;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE payroll.usp_runpayroll(IN par_clientid INTEGER, IN par_payperiodid INTEGER, IN par_force NUMERIC DEFAULT 0, INOUT p_refcur refcursor DEFAULT NULL)
AS 
$BODY$
/*
==============================================================================
  payroll.usp_RunPayroll

  Set-based: one INSERT..SELECT builds every paystub for the period, with
  CROSS APPLY calling the CPP and EI functions.

  CPP and EI both stop once an employee reaches the annual maximum, so each
  deduction is computed as (contribution on year-to-date + this period) minus
  (contribution on year-to-date). That difference automatically tapers to zero
  in the period the cap is reached, without any special-casing.
==============================================================================
*/
DECLARE
    var_taxYear SMALLINT;
    var_periodNumber SMALLINT;
    var_periodEnd DATE;
    var_payDate DATE;
    var_isProcessed NUMERIC(1, 0);
    var_cppEe NUMERIC(19, 2);
    var_eiEe NUMERIC(19, 2);
    var_taxWh NUMERIC(19, 2);
    var_eiMultiplier NUMERIC(9, 4);
    -- Assigned in the body: a DECLARE default runs on block entry, before
    -- var_payDate has been read from the pay period.
    var_remitPeriodEnd DATE;
    var_remitDueDate DATE;
BEGIN
    SELECT
        pp.taxyear, pp.periodnumber, pp.enddate, pp.paydate, (CASE WHEN pp.isprocessed = 1 THEN 1 ELSE 0 END)
        INTO var_taxYear, var_periodNumber, var_periodEnd, var_payDate, var_isProcessed
        FROM payroll.payperiod AS pp
        WHERE pp.payperiodid = par_PayPeriodId AND pp.clientid = par_ClientId;

    IF var_taxYear IS NULL THEN
        RAISE 'Pay period not found for this client.' USING ERRCODE := '50021';
    END IF;

    IF var_isProcessed = 1 AND par_Force = 0 THEN
        RAISE 'This pay period has already been processed.' USING ERRCODE := '50060';
    END IF;

    BEGIN
        /* Writes begin here; see the note at the top of this file. */
        
        
        IF par_Force = 1 THEN
            DELETE FROM payroll.paystub
                WHERE payperiodid = par_PayPeriodId;
        END IF;
        INSERT INTO payroll.paystub (payperiodid, employeeid, grosspay, cppdeducted, cpp2deducted, eideducted, federaltaxdeducted, provincialtaxdeducted, otherdeductions)
        SELECT
            par_PayPeriodId, e.employeeid, calc.grosspay, calc.cppdeducted, calc.cpp2deducted, calc.eideducted, calc.federaltaxdeducted, calc.provincialtaxdeducted, 0
            FROM payroll.employee AS e
            CROSS JOIN LATERAL (SELECT
                CASE e.payfrequency
                    WHEN 'Weekly' THEN 52
                    WHEN 'BiWeekly' THEN 26
                    WHEN 'SemiMonthly' THEN 24
                    ELSE 12
                END AS periodsperyear) AS freq
            LEFT JOIN LATERAL (SELECT
                CAST (ROUND(e.annualsalary / freq.periodsperyear, 2) AS NUMERIC(19, 2)) AS grosspay) AS pay ON true
            CROSS JOIN
            /* Year-to-date gross for this employee before the current period. */
            (SELECT
                COALESCE(SUM(prior.grosspay), 0) AS ytdgross
                FROM payroll.paystub AS prior
                JOIN payroll.payperiod AS pv
                    ON pv.payperiodid = prior.payperiodid
                WHERE prior.employeeid = e.employeeid AND pv.taxyear = var_taxYear AND pv.periodnumber < var_periodNumber) AS ytd
            LEFT JOIN LATERAL (SELECT
                pay.grosspay AS grosspay, tax.fn_cppcontribution(var_taxYear, ytd.ytdgross + pay.grosspay) - tax.fn_cppcontribution(var_taxYear, ytd.ytdgross) AS cppdeducted, tax.fn_cpp2contribution(var_taxYear, ytd.ytdgross + pay.grosspay) - tax.fn_cpp2contribution(var_taxYear, ytd.ytdgross) AS cpp2deducted, tax.fn_eipremium(var_taxYear, ytd.ytdgross + pay.grosspay, e.provinceofemployment) - tax.fn_eipremium(var_taxYear, ytd.ytdgross, e.provinceofemployment) AS eideducted,
                /* Withholding estimate: annualize, tax the amount above the */
                /* TD1 claim, then spread back over the periods in the year. */
                CAST (ROUND(tax.fn_federaltax(var_taxYear,
                CASE
                    WHEN e.annualsalary - e.td1federalamount < 0 THEN 0
                    ELSE e.annualsalary - e.td1federalamount
                END) / freq.periodsperyear, 2) AS NUMERIC(19, 2)) AS federaltaxdeducted, CAST (ROUND(tax.fn_provincialtax(e.provinceofemployment, var_taxYear,
                CASE
                    WHEN e.annualsalary - e.td1provincialamount < 0 THEN 0
                    ELSE e.annualsalary - e.td1provincialamount
                END) / freq.periodsperyear, 2) AS NUMERIC(19, 2)) AS provincialtaxdeducted) AS calc ON true
            WHERE e.employerclientid = par_ClientId AND e.isactive = 1 AND e.hiredate <= var_periodEnd AND (e.terminationdate IS NULL OR e.terminationdate >= var_periodEnd);
        UPDATE payroll.payperiod
        SET isprocessed = 1
            WHERE payperiodid = par_PayPeriodId;
        /* --- roll the period into the employer's remittance ------------- */
        SELECT
            COALESCE(SUM(ps.cppdeducted + ps.cpp2deducted), 0), COALESCE(SUM(ps.eideducted), 0), COALESCE(SUM(ps.federaltaxdeducted + ps.provincialtaxdeducted), 0)
            INTO var_cppEe, var_eiEe, var_taxWh
            FROM payroll.paystub AS ps
            WHERE ps.payperiodid = par_PayPeriodId;
        SELECT
            p.employereimultiplier
            INTO var_eiMultiplier
            FROM ref.payrollrate AS p
            WHERE p.taxyear = var_taxYear;
        var_eiMultiplier := COALESCE(var_eiMultiplier, 1.4);
        /* Remittances are due by the 15th of the month after the pay date. */
        
        var_remitPeriodEnd := (date_trunc('MONTH', var_payDate::TIMESTAMP)
                               + INTERVAL '1 MONTH - 1 day')::DATE;
        var_remitDueDate   := make_date(
                                  date_part('year',  var_remitPeriodEnd + INTERVAL '1 MONTH')::INT,
                                  date_part('month', var_remitPeriodEnd + INTERVAL '1 MONTH')::INT,
                                  15);

        -- The second MERGE AWS SCT could not translate (action item 9996).
        MERGE INTO payroll.remittance AS tgt
        USING (SELECT par_ClientId AS clientid, var_remitPeriodEnd AS periodend) AS src
           ON tgt.clientid = src.clientid AND tgt.periodend = src.periodend
        WHEN MATCHED THEN
            UPDATE SET cppemployee       = tgt.cppemployee + var_cppEe,
                       cppemployer       = tgt.cppemployer + var_cppEe,
                       eiemployee        = tgt.eiemployee  + var_eiEe,
                       eiemployer        = tgt.eiemployer
                                           + ROUND(var_eiEe * var_eiMultiplier, 2),
                       incometaxwithheld = tgt.incometaxwithheld + var_taxWh
        WHEN NOT MATCHED THEN
            INSERT (clientid, periodend, duedate, cppemployee, cppemployer,
                    eiemployee, eiemployer, incometaxwithheld)
            VALUES (par_ClientId, var_remitPeriodEnd, var_remitDueDate,
                    var_cppEe, var_cppEe, var_eiEe,
                    ROUND(var_eiEe * var_eiMultiplier, 2), var_taxWh);

        EXCEPTION
            WHEN OTHERS THEN
                RAISE;
    END;
    OPEN p_refcur FOR
    SELECT
        COUNT(*) AS paystubscreated, SUM(ps.grosspay) AS totalgross, SUM(ps.cppdeducted + ps.cpp2deducted) AS totalcpp, SUM(ps.eideducted) AS totalei, SUM(ps.federaltaxdeducted + ps.provincialtaxdeducted) AS totalincometax, SUM(ps.netpay) AS totalnet
        FROM payroll.paystub AS ps
        WHERE ps.payperiodid = par_PayPeriodId;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE tax.usp_calculatet1(IN par_t1returnid INTEGER, IN par_assessmenttype VARCHAR DEFAULT 'Recalculation', IN par_notes VARCHAR DEFAULT NULL, INOUT p_refcur refcursor DEFAULT NULL)
AS 
$BODY$
/*
==============================================================================
  tax.usp_CalculateT1

  Recomputes a return from the rate tables and records the result as an
  immutable tax.Assessment row alongside the updated return.
==============================================================================
*/
DECLARE
    var_taxYear SMALLINT;
    var_province CHAR(2);
    var_taxableIncome NUMERIC(19, 2);
    var_selfEmpIncome NUMERIC(19, 2);
    var_isLocked NUMERIC(1, 0);
    var_federalTax NUMERIC(19, 2);
    var_provincialTax NUMERIC(19, 2);
    var_federalCredits NUMERIC(19, 2);
    var_provincialCredits NUMERIC(19, 2);
    var_cppSelfEmployment NUMERIC(19, 2);
    var_netFederal NUMERIC(19, 2);
    var_netProvincial NUMERIC(19, 2);
    var_totalPayable NUMERIC(19, 2);
    var_withheld NUMERIC(19, 2);
    var_installments NUMERIC(19, 2);
    var_balanceOwing NUMERIC(19, 2);
BEGIN
    SELECT
        r.taxyear, r.provinceofresidence, r.taxableincome, r.selfemploymentincome, (CASE WHEN y.islocked = 1 THEN 1 ELSE 0 END)
        INTO var_taxYear, var_province, var_taxableIncome, var_selfEmpIncome, var_isLocked
        FROM tax.t1return AS r
        JOIN ref.taxyear AS y
            ON y.taxyear = r.taxyear
        WHERE r.t1returnid = par_T1ReturnId;

    IF var_taxYear IS NULL THEN
        RAISE 'T1 return not found.' USING ERRCODE := '50010';
    END IF;

    IF var_isLocked = 1 THEN
        RAISE 'The tax year is locked; returns for it may not be recalculated.' USING ERRCODE := '50011';
    END IF;
    /* --- calculation --------------------------------------------------- */
    /* Non-refundable credits are claimed at the lowest bracket rate for the */
    /* jurisdiction, which is why ref.NonRefundableCredit stores the rate. */
    SELECT
        COALESCE(SUM(CAST (ROUND(cc.claimedamount * nrc.creditrate, 2) AS NUMERIC(19, 2))), 0)
        INTO var_federalCredits
        FROM tax.creditclaim AS cc
        JOIN ref.nonrefundablecredit AS nrc
            ON nrc.taxyear = cc.taxyear AND LOWER(nrc.jurisdictioncode) = LOWER(cc.jurisdictioncode) AND LOWER(nrc.creditcode) = LOWER(cc.creditcode)
        WHERE cc.t1returnid = par_T1ReturnId AND LOWER(cc.jurisdictioncode) = LOWER('CA');
    SELECT
        COALESCE(SUM(CAST (ROUND(cc.claimedamount * nrc.creditrate, 2) AS NUMERIC(19, 2))), 0)
        INTO var_provincialCredits
        FROM tax.creditclaim AS cc
        JOIN ref.nonrefundablecredit AS nrc
            ON nrc.taxyear = cc.taxyear AND LOWER(nrc.jurisdictioncode) = LOWER(cc.jurisdictioncode) AND LOWER(nrc.creditcode) = LOWER(cc.creditcode)
        WHERE cc.t1returnid = par_T1ReturnId AND LOWER(cc.jurisdictioncode) = LOWER(var_province);
    /* A self-employed taxpayer pays both halves of CPP. */
    SELECT
        r.taxwithheld, r.installmentspaid
        INTO var_withheld, var_installments
        FROM tax.t1return AS r
        WHERE r.t1returnid = par_T1ReturnId;

        -- Assigned here rather than as a DECLARE default: PL/pgSQL evaluates
        -- DECLARE defaults on block entry, before the lookups below have run,
        -- so AWS SCT's version computed these from NULLs.
        var_federalTax        := tax.fn_federaltax(var_taxYear, var_taxableIncome);
        var_provincialTax     := tax.fn_provincialtax(var_province, var_taxYear, var_taxableIncome);
        var_cppSelfEmployment := CASE
        WHEN var_selfEmpIncome > 0 THEN 2 * tax.fn_cppcontribution(var_taxYear, var_selfEmpIncome)
        ELSE 0
    END;
        var_netFederal        := CASE
        WHEN var_federalTax - var_federalCredits < 0 THEN 0
        ELSE var_federalTax - var_federalCredits
    END;
        var_netProvincial     := CASE
        WHEN var_provincialTax - var_provincialCredits < 0 THEN 0
        ELSE var_provincialTax - var_provincialCredits
    END;
        var_totalPayable      := var_netFederal + var_netProvincial + var_cppSelfEmployment;
        var_balanceOwing      := var_totalPayable - var_withheld - var_installments;
    /* --- write --------------------------------------------------------- */
    BEGIN
        /* Writes begin here; see the note at the top of this file. */
        
        
        UPDATE tax.t1return
        SET federaltax = var_federalTax, provincialtax = var_provincialTax, federalcredits = var_federalCredits, provincialcredits = var_provincialCredits, cppselfemployment = var_cppSelfEmployment, totalpayable = var_totalPayable, balanceowing = var_balanceOwing, calculatedat = timezone('UTC', LOCALTIMESTAMP(6))
            WHERE t1returnid = par_T1ReturnId;
        INSERT INTO tax.assessment (t1returnid, assessmenttype, taxableincome, federaltax, provincialtax, totalpayable, balanceowing, calculationnotes)
        VALUES (par_T1ReturnId, par_AssessmentType, var_taxableIncome, var_federalTax, var_provincialTax, var_totalPayable, var_balanceOwing, COALESCE(par_Notes, CONCAT('Calculated from ', var_taxYear, ' brackets for ', var_province, '.')));
        EXCEPTION
            WHEN OTHERS THEN
                RAISE;
    END;
    OPEN p_refcur FOR
    SELECT
        par_T1ReturnId AS t1returnid, var_taxYear AS taxyear, var_province AS provinceofresidence, var_taxableIncome AS taxableincome, var_federalTax AS federaltax, var_provincialCredits AS provincialcredits, var_federalCredits AS federalcredits, var_provincialTax AS provincialtax, var_cppSelfEmployment AS cppselfemployment, var_totalPayable AS totalpayable, var_balanceOwing AS balanceowing, tax.fn_marginalrate(var_province, var_taxYear, var_taxableIncome) AS marginalrate;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE tax.usp_filegsthstreturn(IN par_clientid INTEGER, IN par_periodstart DATE, IN par_periodend DATE, IN par_frequencycode VARCHAR DEFAULT 'Quarterly', IN par_gstpayableaccountnumber VARCHAR DEFAULT '2310', IN par_itcaccountnumber VARCHAR DEFAULT '1330', INOUT par_gsthstreturnid INTEGER DEFAULT NULL, INOUT p_refcur refcursor DEFAULT NULL)
AS 
$BODY$
/*
==============================================================================
  tax.usp_FileGSTHSTReturn

  Derives the GST34 lines from the client's own books rather than accepting
  them as input:

    line 101  credits to revenue accounts over the period
    line 105  credits to the GST/HST payable account (tax collected)
    line 108  debits to the GST/HST recoverable account (input tax credits)

  Note this reads the *client's* ledger (acct.Account / acct.JournalEntry),
  not acct.Invoice - the latter is the practice billing its clients, which is
  the practice's own sales figure, not this client's.
==============================================================================
*/
DECLARE
    var_line101 NUMERIC(19, 2);
    var_line105 NUMERIC(19, 2);
    var_line108 NUMERIC(19, 2);
    var_dueDate DATE DEFAULT par_PeriodEnd + (1::NUMERIC || ' MONTH')::INTERVAL;
BEGIN
    IF NOT EXISTS (SELECT
        1
        FROM client.client
        WHERE clientid = par_ClientId) THEN
        RAISE 'Unknown client.' USING ERRCODE := '50021';
    END IF;
    /* Two periods overlap when each starts before the other ends. */

    IF EXISTS (SELECT
        1
        FROM tax.gsthstreturn AS g
        WHERE g.clientid = par_ClientId AND g.periodstart <= par_PeriodEnd AND g.periodend >= par_PeriodStart) THEN
        RAISE 'A GST/HST return already exists overlapping this period.' USING ERRCODE := '50030';
    END IF;
    /* Line 101: net credits to revenue accounts (a credit increases revenue). */
    SELECT
        COALESCE(SUM(l.creditamount - l.debitamount), 0)
        INTO var_line101
        FROM acct.journalline AS l
        JOIN acct.journalentry AS e
            ON e.journalentryid = l.journalentryid
        JOIN acct.account AS a
            ON a.accountid = l.accountid
        JOIN ref.accounttype AS t
            ON LOWER(t.accounttypecode) = LOWER(a.accounttypecode)
        WHERE a.clientid = par_ClientId AND LOWER(t.accounttypecode) = LOWER('Revenue') AND e.isposted = 1 AND e.entrydate BETWEEN par_PeriodStart AND par_PeriodEnd;
    /* Line 105: tax collected, accumulated as credits on the payable account. */
    SELECT
        COALESCE(SUM(l.creditamount - l.debitamount), 0)
        INTO var_line105
        FROM acct.journalline AS l
        JOIN acct.journalentry AS e
            ON e.journalentryid = l.journalentryid
        JOIN acct.account AS a
            ON a.accountid = l.accountid
        WHERE a.clientid = par_ClientId AND LOWER(a.accountnumber) = LOWER(par_GSTPayableAccountNumber) AND e.isposted = 1 AND e.entrydate BETWEEN par_PeriodStart AND par_PeriodEnd;

    IF var_line101 < 0 THEN
        var_line101 := 0;
    END IF;

    IF var_line105 < 0 THEN
        var_line105 := 0;
    END IF;
    /* Line 108: input tax credits, accumulated as debits on the recoverable */
    /* account over the period. */
    SELECT
        COALESCE(SUM(l.debitamount - l.creditamount), 0)
        INTO var_line108
        FROM acct.journalline AS l
        JOIN acct.journalentry AS e
            ON e.journalentryid = l.journalentryid
        JOIN acct.account AS a
            ON a.accountid = l.accountid
        WHERE a.clientid = par_ClientId AND LOWER(a.accountnumber) = LOWER(par_ITCAccountNumber) AND e.isposted = 1 AND e.entrydate BETWEEN par_PeriodStart AND par_PeriodEnd;

    IF var_line108 < 0 THEN
        var_line108 := 0;
    END IF;
    /* A GST/HST return is due one month after the period end for monthly and */
    /* quarterly filers. */

    BEGIN
        /* Writes begin here; see the note at the top of this file. */
        
        
        -- Same simplification as the other procedures: RETURNING ... INTO
        -- instead of staging the generated key through a temp table.
        INSERT INTO tax.gsthstreturn (clientid, periodstart, periodend, frequencycode, line101sales, line105taxcollected, line108inputtaxcredits, filingduedate, filedat, status)
        VALUES (par_ClientId, par_PeriodStart, par_PeriodEnd, par_FrequencyCode, var_line101, var_line105, var_line108, var_dueDate, timezone('UTC', LOCALTIMESTAMP(6)), 'Filed')
        RETURNING gsthstreturnid INTO par_GSTHSTReturnId;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE;
    END;
    OPEN p_refcur FOR
    SELECT
        g.gsthstreturnid, g.periodstart, g.periodend, g.line101sales, g.line105taxcollected, g.line108inputtaxcredits, g.line109nettax, g.balancedue, g.filingduedate
        FROM tax.gsthstreturn AS g
        WHERE g.gsthstreturnid = par_GSTHSTReturnId;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE tax.usp_generateclientyearendpackage(IN par_clientid INTEGER, IN par_taxyear INTEGER, INOUT p_refcur refcursor, INOUT p_refcur_2 refcursor, INOUT p_refcur_3 refcursor, INOUT p_refcur_4 refcursor, INOUT p_refcur_5 refcursor)
AS 
$BODY$
/*
==============================================================================
  tax.usp_GenerateClientYearEndPackage

  Returns five result sets in one round trip - the shape a reporting client
  binds to, and a useful target for a harness that has to assert across
  multiple results from a single call.
==============================================================================
*/
DECLARE
    var_taxableIncome NUMERIC(19, 2);
BEGIN
    IF NOT EXISTS (SELECT
        1
        FROM client.client
        WHERE clientid = par_ClientId) THEN
        RAISE 'Unknown client.' USING ERRCODE := '50021';
    END IF;
    /* --- 1. who the client is ------------------------------------------ */
    OPEN p_refcur FOR
    SELECT
        d.clientid, d.clientcode, d.displayname, d.clienttype, d.provincecode, d.provincename, d.primaryemail, d.line1, d.city, d.postalcode, d.isactive
        FROM client.vw_clientdirectory AS d
        WHERE d.clientid = par_ClientId;
    /* --- 2. income as reported on slips --------------------------------- */
    OPEN p_refcur_2 FOR
    SELECT
        st.employmentincome, st.investmentincome, st.selfemploymentincome, st.pensionincome, st.otherincome, st.deductions, st.taxwithheld, st.cppcontributions, st.eipremiums, st.slipcount
        FROM tax.fn_clientsliptotals(par_ClientId, par_TaxYear)
            AS st;
    /* --- 3. the return, assessed vs recalculated ------------------------ */
    OPEN p_refcur_3 FOR
    SELECT
        s.t1returnid, s.taxyear, s.filingstatus, s.totalincome, s.netincome, s.taxableincome, s.assessedfederaltax, s.recalculatedfederaltax, s.federaltaxvariance, s.assessedprovincialtax, s.recalculatedprovincialtax, s.provincialtaxvariance, s.marginalrate, s.averagerate, s.totalpayable, s.balanceowing
        FROM tax.vw_t1returnsummary AS s
        WHERE s.clientid = par_ClientId AND s.taxyear = par_TaxYear;
    /* --- 4. federal bracket breakdown ----------------------------------- */
    SELECT
        r.taxableincome
        INTO var_taxableIncome
        FROM tax.t1return AS r
        WHERE r.clientid = par_ClientId AND r.taxyear = par_TaxYear;
    OPEN p_refcur_4 FOR
    SELECT
        bb.ordinal, bb.lowerbound, bb.upperbound, bb.rate, bb.incomeinbracket, bb.taxinbracket, bb.cumulativetax
        FROM tax.fn_taxbracketbreakdown('CA', par_TaxYear, COALESCE(var_taxableIncome, 0))
            AS bb
        ORDER BY bb.ordinal NULLS FIRST;
    /* --- 5. what the client still owes the practice and the CRA --------- */
    OPEN p_refcur_5 FOR
    SELECT
        ag.invoicenumber, ag.invoicedate, ag.duedate, ag.total, ag.outstandingamount, ag.daysoverdue, ag.agingbucket
        FROM acct.fn_invoiceaging(((timezone('UTC', LOCALTIMESTAMP(6)))::date))
            AS ag
        WHERE ag.clientid = par_ClientId
        ORDER BY ag.duedate NULLS FIRST;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE tax.usp_importslips(IN par_clientid INTEGER, IN par_taxyear INTEGER, IN par_slipsjson TEXT, INOUT p_refcur refcursor)
AS 
$BODY$
/*
==============================================================================
  tax.usp_ImportSlips

  Slips arrive as JSON, each with a nested array of boxes. OPENJSON ... WITH
  projects both levels into relational shape, and MERGE makes re-importing the
  same payload a no-op rather than a duplicate.
==============================================================================
*/
BEGIN
    -- ISJSON has no direct equivalent and SCT dropped the check (action item
    -- 7939). pg_input_is_valid (PostgreSQL 16+) tests whether a string would
    -- cast to a type without raising, which is exactly ISJSON's job.
    IF par_SlipsJson IS NULL OR NOT pg_input_is_valid(par_SlipsJson, 'jsonb') THEN
        RAISE 'The slips payload is not valid JSON.' USING ERRCODE := '50020';
    END IF;

    IF NOT EXISTS (SELECT
        1
        FROM client.client
        WHERE clientid = par_ClientId) THEN
        RAISE 'Unknown client.' USING ERRCODE := '50021';
    END IF;

    BEGIN
        /* Writes begin here; see the note at the top of this file. */
        
        
        DROP TABLE IF EXISTS incoming$usp_importslips;
        CREATE TEMPORARY TABLE incoming$usp_importslips
        (sliptypecode VARCHAR(10) NOT NULL,
            issuername VARCHAR(150) NOT NULL,
            issuerbusinessnumber CHAR(9) NULL,
            slipreference VARCHAR(40) NOT NULL,
            receiveddate DATE NULL,
            isamended NUMERIC(1, 0) NOT NULL,
            boxes TEXT NULL);

        -- OPENJSON ... WITH becomes jsonb_to_recordset (action item 7940).
        -- The column names are double-quoted so they keep their camelCase and
        -- match the JSON keys: an unquoted identifier folds to lower case and
        -- would silently match nothing, leaving every column NULL.
        INSERT INTO incoming$usp_importslips
            (sliptypecode, issuername, issuerbusinessnumber, slipreference,
             receiveddate, isamended, boxes)
        SELECT j."slipType", j."issuer", j."issuerBn", j."reference",
               j."receivedDate",
               -- "amended" is a JSON boolean; the column it lands in is the
               -- NUMERIC(1,0) that SQL Server's BIT became.
               CASE WHEN COALESCE(j."amended", false) THEN 1 ELSE 0 END,
               j."boxes"::TEXT
          FROM jsonb_to_recordset(par_SlipsJson::JSONB) AS j(
                   "slipType"    VARCHAR(10),
                   "issuer"      VARCHAR(150),
                   "issuerBn"    CHAR(9),
                   "reference"   VARCHAR(40),
                   "receivedDate" DATE,
                   "amended"     BOOLEAN,
                   "boxes"       JSONB);

        DROP TABLE IF EXISTS slipids$usp_importslips;
        CREATE TEMPORARY TABLE slipids$usp_importslips
        (slipid INTEGER NOT NULL,
            slipreference VARCHAR(40) NOT NULL,
            sliptypecode VARCHAR(10) NOT NULL);

        -- The third MERGE AWS SCT could not translate (action item 9996).
        MERGE INTO tax.slip AS tgt
        USING (SELECT * FROM incoming$usp_importslips) AS src
           ON tgt.clientid = par_ClientId
          AND tgt.taxyear  = par_TaxYear
          AND LOWER(tgt.sliptypecode)  = LOWER(src.sliptypecode)
          AND LOWER(tgt.slipreference) = LOWER(src.slipreference)
        WHEN MATCHED THEN
            UPDATE SET issuername           = src.issuername,
                       issuerbusinessnumber = src.issuerbusinessnumber,
                       receiveddate         = src.receiveddate,
                       isamended            = src.isamended
        WHEN NOT MATCHED THEN
            INSERT (clientid, taxyear, sliptypecode, issuername,
                    issuerbusinessnumber, slipreference, receiveddate, isamended)
            VALUES (par_ClientId, par_TaxYear, src.sliptypecode, src.issuername,
                    src.issuerbusinessnumber, src.slipreference,
                    src.receiveddate, src.isamended);

        -- The T-SQL used MERGE ... OUTPUT to capture the generated SlipIds.
        -- MERGE ... RETURNING is PostgreSQL 17, so on 16 the ids are read back
        -- by natural key instead - the same set of rows either way.
        INSERT INTO slipids$usp_importslips (slipid, slipreference, sliptypecode)
        SELECT sl.slipid, sl.slipreference, sl.sliptypecode
          FROM tax.slip                  AS sl
          JOIN incoming$usp_importslips  AS i
            ON LOWER(sl.slipreference) = LOWER(i.slipreference)
           AND LOWER(sl.sliptypecode)  = LOWER(i.sliptypecode)
         WHERE sl.clientid = par_ClientId
           AND sl.taxyear  = par_TaxYear;

        /* Second level: the boxes nested inside each slip. */
        DROP TABLE IF EXISTS boxes$usp_importslips;
        CREATE TEMPORARY TABLE boxes$usp_importslips
        (slipid INTEGER NOT NULL,
            sliptypecode VARCHAR(10) NOT NULL,
            boxnumber VARCHAR(10) NOT NULL,
            amount NUMERIC(19, 2) NOT NULL,
            PRIMARY KEY (slipid, boxnumber));

        -- The nested array, shredded the same way. CROSS JOIN LATERAL is the
        -- equivalent of the T-SQL CROSS APPLY over OPENJSON.
        INSERT INTO boxes$usp_importslips (slipid, sliptypecode, boxnumber, amount)
        SELECT sid.slipid, sid.sliptypecode, b."box", b."amount"
          FROM incoming$usp_importslips AS i
          JOIN slipids$usp_importslips  AS sid
            ON LOWER(sid.slipreference) = LOWER(i.slipreference)
           AND LOWER(sid.sliptypecode)  = LOWER(i.sliptypecode)
          CROSS JOIN LATERAL jsonb_to_recordset(i.boxes::JSONB) AS b(
                   "box"    VARCHAR(10),
                   "amount" NUMERIC(19, 2));

        MERGE INTO tax.slipbox AS tgt
        USING (SELECT
            *
            FROM boxes$usp_importslips) AS src
                ON tgt.slipid = src.slipid AND LOWER(tgt.boxnumber) = LOWER(src.boxnumber)
        WHEN MATCHED
                THEN UPDATE SET amount = src.amount
        WHEN NOT MATCHED
                THEN INSERT (slipid, sliptypecode, boxnumber, amount)
                    VALUES (src.slipid, src.sliptypecode, src.boxnumber, src.amount);
        OPEN p_refcur FOR
        SELECT
            (SELECT
                COUNT(*)
                FROM slipids$usp_importslips) AS slipsprocessed, (SELECT
                COUNT(*)
                FROM boxes$usp_importslips) AS boxesprocessed;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE;
                DROP TABLE IF EXISTS incoming$usp_importslips;
                DROP TABLE IF EXISTS slipids$usp_importslips;
                DROP TABLE IF EXISTS boxes$usp_importslips;
    END;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE tax.usp_recalculateallreturns(IN par_taxyear INTEGER DEFAULT NULL, IN par_continueonerror NUMERIC DEFAULT 1, IN par_includefailuredetail NUMERIC DEFAULT 1, INOUT p_refcur refcursor DEFAULT NULL, INOUT p_refcur_2 refcursor DEFAULT NULL)
AS 
$BODY$
/*
==============================================================================
  tax.usp_RecalculateAllReturns

  Batch driver. Each return is recalculated inside its own TRY/CATCH so that a
  single bad return (a locked year, say) does not abandon the rest of the
  batch; the failures come back as a result set instead of an exception.
==============================================================================
*/
/* Set to 0 to return only the summary. A caller using INSERT ... EXEC can */
/* capture one result set, not two, so the detail rows have to be optional. */
DECLARE
    var_id INTEGER;
    error_catch$ERROR_NUMBER TEXT;
    error_catch$ERROR_SEVERITY TEXT;
    error_catch$ERROR_STATE TEXT;
    error_catch$ERROR_LINE TEXT;
    error_catch$ERROR_PROCEDURE TEXT;
    error_catch$ERROR_MESSAGE TEXT;
    var_errNumber INTEGER;
    var_errMessage VARCHAR(400);
BEGIN
    DROP TABLE IF EXISTS results$usp_recalculateallreturns;
    CREATE TEMPORARY TABLE results$usp_recalculateallreturns
    (t1returnid INTEGER NOT NULL,
        succeeded NUMERIC(1, 0) NOT NULL,
        errornumber INTEGER NULL,
        errormessage VARCHAR(400) NULL);
    DROP TABLE IF EXISTS ids$usp_recalculateallreturns;
    CREATE TEMPORARY TABLE ids$usp_recalculateallreturns
    (t1returnid INTEGER NOT NULL PRIMARY KEY);
    INSERT INTO ids$usp_recalculateallreturns (t1returnid)
    SELECT
        r.t1returnid
        FROM tax.t1return AS r
        WHERE (par_TaxYear IS NULL OR r.taxyear = par_TaxYear);

    WHILE EXISTS (SELECT
        1
        FROM ids$usp_recalculateallreturns) LOOP
        SELECT
            t1returnid
            INTO var_id
            FROM ids$usp_recalculateallreturns
            ORDER BY t1returnid NULLS FIRST
            LIMIT 1;
        var_errMessage := LEFT(error_catch$ERROR_MESSAGE, 400);
        var_errNumber := error_catch$ERROR_NUMBER;

        BEGIN
            CALL tax.usp_calculatet1(par_T1ReturnId := var_id, par_AssessmentType := 'Recalculation');
            INSERT INTO results$usp_recalculateallreturns (t1returnid, succeeded)
            VALUES (var_id, 1);
            EXCEPTION
                WHEN OTHERS THEN
                    /* No ROLLBACK here, deliberately: this procedure is meant to be */
                    /* consumable via INSERT ... EXEC, and ROLLBACK is illegal inside */
                    /* one (error 3915). Recording the failure and continuing therefore */
                    /* depends on usp_CalculateT1 not leaving a doomed transaction */
                    /* behind - which is exactly what the XACT_ABORT discipline */
                    /* described at the top of this file guarantees. */
                    error_catch$ERROR_NUMBER := '0';
                    error_catch$ERROR_SEVERITY := '0';
                    error_catch$ERROR_LINE := '0';
                    error_catch$ERROR_PROCEDURE := 'USP_RECALCULATEALLRETURNS';
                    GET STACKED DIAGNOSTICS error_catch$ERROR_STATE = RETURNED_SQLSTATE,
                        error_catch$ERROR_MESSAGE = MESSAGE_TEXT;
                    INSERT INTO results$usp_recalculateallreturns (t1returnid, succeeded, errornumber, errormessage)
                    VALUES (var_id, 0, var_errNumber, var_errMessage);

                    IF par_ContinueOnError = 0 THEN
                        DELETE FROM ids$usp_recalculateallreturns;
                        /* stop the loop */
                        EXIT;
                    END IF;
                    DROP TABLE IF EXISTS results$usp_recalculateallreturns;
                    DROP TABLE IF EXISTS ids$usp_recalculateallreturns;
        END;
        DELETE FROM ids$usp_recalculateallreturns
            WHERE t1returnid = var_id;
    END LOOP;
    OPEN p_refcur FOR
    SELECT
        COALESCE(SUM(CASE
            WHEN succeeded = 1 THEN 1
            ELSE 0
        END), 0) AS succeeded, COALESCE(SUM(CASE
            WHEN succeeded = 0 THEN 1
            ELSE 0
        END), 0) AS failed, COUNT(*) AS total
        FROM results$usp_recalculateallreturns;

    IF par_IncludeFailureDetail = 1 THEN
        OPEN p_refcur_2 FOR
        SELECT
            t1returnid, errornumber, errormessage
            FROM results$usp_recalculateallreturns
            WHERE succeeded = 0
            ORDER BY t1returnid NULLS FIRST;
    END IF;
END;
$BODY$
LANGUAGE plpgsql;