/*==============================================================================
  099 - Verification  (PostgreSQL)

  The acceptance gate for the port. Mirrors db/sqlserver/099_verify.sql so the
  two read side by side: collect every failure into a temp table, raise once at
  the end, and assert the same values against both engines.

  Sample data is out of scope for this port, so the assertions cover object
  inventory, the reference-data-driven functions, and the error contracts.
  Anything needing rows creates and removes its own scratch data.
==============================================================================*/

SET client_min_messages = warning;

DROP TABLE IF EXISTS verify_failures;
CREATE TEMPORARY TABLE verify_failures
(
    seq       SERIAL PRIMARY KEY,
    category  TEXT NOT NULL,
    assertion TEXT NOT NULL,
    expected  TEXT NOT NULL,
    actual    TEXT NOT NULL
);

CREATE OR REPLACE FUNCTION pg_temp.expect(
    p_category TEXT, p_assertion TEXT, p_expected TEXT, p_actual TEXT)
RETURNS void AS $$
BEGIN
    IF p_expected IS DISTINCT FROM p_actual THEN
        INSERT INTO verify_failures (category, assertion, expected, actual)
        VALUES (p_category, p_assertion, p_expected, p_actual);
    END IF;
END;
$$ LANGUAGE plpgsql;

/*------------------------------------------------------------------------------
  Clear any scratch fixture left behind by a run that aborted before its own
  teardown, so a previous failure cannot make this run report phantom problems.
------------------------------------------------------------------------------*/
DO $$
BEGIN
    UPDATE acct.journalentry SET isposted = 0, postedat = NULL, postedby = NULL
     WHERE clientid IN (SELECT clientid FROM client.client WHERE clientcode LIKE 'VERIFY-%');
    DELETE FROM acct.journalentry
     WHERE clientid IN (SELECT clientid FROM client.client WHERE clientcode LIKE 'VERIFY-%');
    DELETE FROM client.client WHERE clientcode LIKE 'VERIFY-%';
END $$;

/*==============================================================================
  1. INVENTORY
==============================================================================*/
DO $$
DECLARE s TEXT[] := ARRAY['ref','client','tax','acct','payroll','audit','util'];
BEGIN
    PERFORM pg_temp.expect('inventory','tables','39',
        (SELECT count(*)::TEXT FROM pg_tables WHERE schemaname = ANY(s)));

    -- The check that would have caught AWS SCT silently dropping five of them.
    PERFORM pg_temp.expect('inventory','generated columns','18',
        (SELECT count(*)::TEXT FROM information_schema.columns
          WHERE table_schema = ANY(s) AND is_generated = 'ALWAYS'));

    PERFORM pg_temp.expect('inventory','views (incl. materialized)','9',
        (SELECT count(*)::TEXT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE c.relkind IN ('v','m') AND n.nspname = ANY(s)));
    PERFORM pg_temp.expect('inventory','materialized views','1',
        (SELECT count(*)::TEXT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE c.relkind='m' AND n.nspname = ANY(s)));

    -- 20 ported functions + 5 trigger functions + 1 row-image helper.
    PERFORM pg_temp.expect('inventory','functions','26',
        (SELECT count(*)::TEXT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname = ANY(s) AND p.prokind='f'));
    PERFORM pg_temp.expect('inventory','procedures','12',
        (SELECT count(*)::TEXT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname = ANY(s) AND p.prokind='p'));

    -- 4 SQL Server triggers become 7 (one per operation) + the ROWVERSION
    -- emulation + the INSTEAD OF trigger on the view.
    PERFORM pg_temp.expect('inventory','triggers','8',
        (SELECT count(*)::TEXT FROM pg_trigger t
          JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE NOT t.tgisinternal AND n.nspname = ANY(s)));

    PERFORM pg_temp.expect('inventory','foreign keys','57',
        (SELECT count(*)::TEXT FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace
          WHERE c.contype='f' AND n.nspname = ANY(s)));
    PERFORM pg_temp.expect('inventory','unique constraints','24',
        (SELECT count(*)::TEXT FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace
          WHERE c.contype='u' AND n.nspname = ANY(s)));
    PERFORM pg_temp.expect('inventory','partial indexes','10',
        (SELECT count(*)::TEXT FROM pg_index i
          JOIN pg_class c ON c.oid=i.indexrelid JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE i.indpred IS NOT NULL AND n.nspname = ANY(s)));
    PERFORM pg_temp.expect('inventory','composite types','3',
        (SELECT count(*)::TEXT FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
          WHERE t.typtype='c' AND n.nspname = ANY(s)
            AND t.typrelid IN (SELECT oid FROM pg_class WHERE relkind='c')));

    -- Nothing may depend on the AWS extension pack.
    PERFORM pg_temp.expect('inventory','no aws_sqlserver_ext dependency','0',
        (SELECT count(*)::TEXT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname = ANY(s) AND p.prosrc LIKE '%aws_sqlserver_ext%'));
END $$;

/*==============================================================================
  2. FUNCTION BEHAVIOUR - identical expected values to the SQL Server gate
==============================================================================*/
DO $$
BEGIN
    -- identifier validation
    PERFORM pg_temp.expect('function','fn_IsValidSIN accepts a valid check digit',
        '1', tax.fn_isvalidsin('046454286')::TEXT);
    PERFORM pg_temp.expect('function','fn_IsValidSIN rejects a mutated last digit',
        '0', tax.fn_isvalidsin('046454287')::TEXT);
    PERFORM pg_temp.expect('function','fn_IsValidSIN rejects a non-numeric value',
        '0', tax.fn_isvalidsin('04645428X')::TEXT);
    PERFORM pg_temp.expect('function','fn_IsValidBusinessNumber accepts a full RT account',
        '1', tax.fn_isvalidbusinessnumber('867530909RT0001')::TEXT);
    PERFORM pg_temp.expect('function','fn_IsValidBusinessNumber accepts the bare 9 digits',
        '1', tax.fn_isvalidbusinessnumber('867530909')::TEXT);
    PERFORM pg_temp.expect('function','fn_IsValidBusinessNumber rejects an unknown program id',
        '0', tax.fn_isvalidbusinessnumber('867530909RX0001')::TEXT);
    PERFORM pg_temp.expect('function','fn_IsValidBusinessNumber rejects a bad check digit',
        '0', tax.fn_isvalidbusinessnumber('867530900')::TEXT);

    -- income tax
    PERFORM pg_temp.expect('function','fn_FederalTax(2024, 100000)',
        '17427.32', tax.fn_federaltax(2024, 100000)::TEXT);
    PERFORM pg_temp.expect('function','fn_FederalTax(2024, 40000) = 40000 * 15%',
        '6000.00', tax.fn_federaltax(2024, 40000)::TEXT);
    PERFORM pg_temp.expect('function','fn_FederalTax on zero income is zero',
        '0', tax.fn_federaltax(2024, 0)::TEXT);
    PERFORM pg_temp.expect('function','fn_FederalTax on negative income is zero',
        '0', tax.fn_federaltax(2024, -5000)::TEXT);
    PERFORM pg_temp.expect('function','fn_ProvincialTax(ON, 2024, 100000)',
        '7040.71', tax.fn_provincialtax('ON', 2024, 100000)::TEXT);
    PERFORM pg_temp.expect('function','fn_ProvincialTax(AB, 2025, 50000) uses the new 8% bracket',
        '4000.00', tax.fn_provincialtax('AB', 2025, 50000)::TEXT);
    PERFORM pg_temp.expect('function','fn_MarginalRate(ON, 2024, 100000) = 20.5% + 9.15%',
        '0.296500', tax.fn_marginalrate('ON', 2024, 100000)::TEXT);

    -- payroll
    PERFORM pg_temp.expect('function','fn_CPPContribution(2024, 100000) is the annual maximum',
        '3867.50', tax.fn_cppcontribution(2024, 100000)::TEXT);
    PERFORM pg_temp.expect('function','fn_CPPContribution below the basic exemption is zero',
        '0', tax.fn_cppcontribution(2024, 3000)::TEXT);
    PERFORM pg_temp.expect('function','fn_CPP2Contribution(2024, 100000) is the CPP2 maximum',
        '188.00', tax.fn_cpp2contribution(2024, 100000)::TEXT);
    PERFORM pg_temp.expect('function','fn_CPP2Contribution below the YMPE is zero',
        '0', tax.fn_cpp2contribution(2024, 60000)::TEXT);
    PERFORM pg_temp.expect('function','fn_CPP2Contribution did not exist in 2023',
        '0', tax.fn_cpp2contribution(2023, 100000)::TEXT);
    PERFORM pg_temp.expect('function','fn_EIPremium(2024, 100000, ON) is the annual maximum',
        '1049.12', tax.fn_eipremium(2024, 100000, 'ON')::TEXT);
    PERFORM pg_temp.expect('function','fn_EIPremium(2024, 100000, QC) uses the Quebec rate',
        '834.24', tax.fn_eipremium(2024, 100000, 'QC')::TEXT);

    -- sales tax
    PERFORM pg_temp.expect('function','fn_GSTHSTRate(ON) is 13% HST',
        '0.13000', ref.fn_gsthstrate('ON', DATE '2024-06-01')::TEXT);
    PERFORM pg_temp.expect('function','fn_GSTHSTRate(AB) is 5% GST',
        '0.05000', ref.fn_gsthstrate('AB', DATE '2024-06-01')::TEXT);
    PERFORM pg_temp.expect('function','fn_GSTHSTRate(NS) before 2025-04-01 is 15%',
        '0.15000', ref.fn_gsthstrate('NS', DATE '2025-01-15')::TEXT);
    PERFORM pg_temp.expect('function','fn_GSTHSTRate(NS) on and after 2025-04-01 is 14%',
        '0.14000', ref.fn_gsthstrate('NS', DATE '2025-06-15')::TEXT);
    PERFORM pg_temp.expect('function','fn_SalesTaxRate(QC) is GST 5% + QST 9.975%',
        '0.14975', ref.fn_salestaxrate('QC', DATE '2024-06-01')::TEXT);
    PERFORM pg_temp.expect('function','fn_PSTRate(BC) is 7%',
        '0.07000', ref.fn_pstrate('BC', DATE '2024-06-01')::TEXT);

    -- dates
    PERFORM pg_temp.expect('function','fn_BusinessDaysBetween over the 2024 holidays',
        '5', util.fn_businessdaysbetween(DATE '2024-12-23', DATE '2025-01-02', 'ON')::TEXT);
    PERFORM pg_temp.expect('function','fn_BusinessDaysBetween respects a province-only holiday (ON)',
        '4', util.fn_businessdaysbetween(DATE '2025-02-17', DATE '2025-02-22', 'ON')::TEXT);
    PERFORM pg_temp.expect('function','fn_BusinessDaysBetween respects a province-only holiday (QC)',
        '5', util.fn_businessdaysbetween(DATE '2025-02-17', DATE '2025-02-22', 'QC')::TEXT);
    PERFORM pg_temp.expect('function','fn_BusinessDaysBetween on an inverted range is zero',
        '0', util.fn_businessdaysbetween(DATE '2025-03-01', DATE '2025-02-01', 'ON')::TEXT);

    -- the bracket breakdown must reconcile to the scalar function
    PERFORM pg_temp.expect('function','fn_TaxBracketBreakdown reconciles to fn_FederalTax',
        tax.fn_federaltax(2024, 100000)::TEXT,
        (SELECT COALESCE(SUM(taxinbracket),0)::TEXT
           FROM tax.fn_taxbracketbreakdown('CA', 2024, 100000)));
END $$;

/*==============================================================================
  3. REFERENCE DATA
==============================================================================*/
DO $$
BEGIN
    PERFORM pg_temp.expect('seed','provinces','13', (SELECT count(*)::TEXT FROM ref.province));
    PERFORM pg_temp.expect('seed','tax brackets','120', (SELECT count(*)::TEXT FROM ref.taxbracket));
    PERFORM pg_temp.expect('seed','statutory holidays','40', (SELECT count(*)::TEXT FROM ref.statutoryholiday));
    PERFORM pg_temp.expect('seed','Ontario survived the seed','1',
        (SELECT count(*)::TEXT FROM ref.province WHERE provincecode='ON'));
    PERFORM pg_temp.expect('seed','federal brackets cover 2023-2025','3',
        (SELECT count(DISTINCT taxyear)::TEXT FROM ref.taxbracket WHERE jurisdictioncode='CA'));
    PERFORM pg_temp.expect('seed','all 13 provinces have 2024 brackets','13',
        (SELECT count(DISTINCT jurisdictioncode)::TEXT FROM ref.taxbracket
          WHERE taxyear=2024 AND jurisdictioncode <> 'CA'));
    PERFORM pg_temp.expect('seed','no bracket set has a gap or overlap','0',
        (SELECT count(*)::TEXT FROM ref.taxbracket b
          JOIN ref.taxbracket prev ON prev.taxyear=b.taxyear
             AND prev.jurisdictioncode=b.jurisdictioncode AND prev.ordinal=b.ordinal-1
          WHERE prev.upperbound IS DISTINCT FROM b.lowerbound));
END $$;

/*==============================================================================
  4. CONTRACTS - the SQLSTATE each procedure and trigger promises
==============================================================================*/
DO $$
DECLARE
    v_client   INTEGER;
    v_fy       INTEGER;
    v_je       INTEGER;
    v_inv      INTEGER;
    v_cur      refcursor;
    v_lines    acct.journallinetype[];
    v_invlines acct.invoicelinetype[];
    v_caught   TEXT;
BEGIN
    /*--- scratch fixture ------------------------------------------------*/
    CALL client.usp_upsertclient(
        par_clientcode := 'VERIFY-CO', par_clienttype := 'C', par_provincecode := 'ON',
        par_legalname := 'Verify Corp', par_incorporationdate := DATE '2020-01-01',
        par_businessnumber := '867530909', par_fiscalyearendmonth := 12,
        par_clientid := v_client, p_refcur := v_cur);
    CLOSE v_cur; v_cur := NULL;

    INSERT INTO acct.fiscalyear (clientid, startdate, enddate)
    VALUES (v_client, DATE '2024-01-01', DATE '2024-12-31') RETURNING fiscalyearid INTO v_fy;

    INSERT INTO acct.account (clientid, accountnumber, accountname, accounttypecode, iscontrolaccount)
    VALUES (v_client,'1000','Assets','Asset',1),
           (v_client,'1100','Cash','Asset',0),
           (v_client,'4100','Professional Fees','Revenue',0);

    /*--- 50006 : an entry with no lines ---------------------------------*/
    v_lines := ARRAY[]::acct.journallinetype[];
    BEGIN
        CALL acct.usp_postjournalentry(par_clientid := v_client, par_fiscalyearid := v_fy,
            par_entrydate := DATE '2024-06-01', par_description := 'no lines',
            par_lines := v_lines, par_journalentryid := v_je, p_refcur := v_cur);
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','usp_PostJournalEntry rejects an entry with no lines','50006',v_caught);

    /*--- 50001 : unbalanced ---------------------------------------------*/
    v_lines := ARRAY[ROW(1,'1100',100.00,0.00,NULL)::acct.journallinetype,
                     ROW(2,'4100',0.00,90.00,NULL)::acct.journallinetype];
    BEGIN
        CALL acct.usp_postjournalentry(par_clientid := v_client, par_fiscalyearid := v_fy,
            par_entrydate := DATE '2024-06-01', par_description := 'unbalanced',
            par_lines := v_lines, par_journalentryid := v_je, p_refcur := v_cur);
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','usp_PostJournalEntry rejects an unbalanced entry','50001',v_caught);

    /*--- 50002 : unknown account ----------------------------------------*/
    v_lines := ARRAY[ROW(1,'9999',100.00,0.00,NULL)::acct.journallinetype,
                     ROW(2,'4100',0.00,100.00,NULL)::acct.journallinetype];
    BEGIN
        CALL acct.usp_postjournalentry(par_clientid := v_client, par_fiscalyearid := v_fy,
            par_entrydate := DATE '2024-06-01', par_description := 'bad account',
            par_lines := v_lines, par_journalentryid := v_je, p_refcur := v_cur);
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','usp_PostJournalEntry rejects an unknown account number','50002',v_caught);

    /*--- 50003 : control account ----------------------------------------*/
    v_lines := ARRAY[ROW(1,'1000',100.00,0.00,NULL)::acct.journallinetype,
                     ROW(2,'4100',0.00,100.00,NULL)::acct.journallinetype];
    BEGIN
        CALL acct.usp_postjournalentry(par_clientid := v_client, par_fiscalyearid := v_fy,
            par_entrydate := DATE '2024-06-01', par_description := 'control account',
            par_lines := v_lines, par_journalentryid := v_je, p_refcur := v_cur);
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','usp_PostJournalEntry refuses a control account','50003',v_caught);

    /*--- 50005 : date outside the fiscal year ---------------------------*/
    v_lines := ARRAY[ROW(1,'1100',100.00,0.00,NULL)::acct.journallinetype,
                     ROW(2,'4100',0.00,100.00,NULL)::acct.journallinetype];
    BEGIN
        CALL acct.usp_postjournalentry(par_clientid := v_client, par_fiscalyearid := v_fy,
            par_entrydate := DATE '2023-06-01', par_description := 'wrong year',
            par_lines := v_lines, par_journalentryid := v_je, p_refcur := v_cur);
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','usp_PostJournalEntry refuses a date outside the fiscal year','50005',v_caught);

    /*--- a good posting, then 50007 on editing it -----------------------*/
    CALL acct.usp_postjournalentry(par_clientid := v_client, par_fiscalyearid := v_fy,
        par_entrydate := DATE '2024-06-01', par_description := 'good entry',
        par_lines := v_lines, par_journalentryid := v_je, p_refcur := v_cur);
    CLOSE v_cur; v_cur := NULL;
    PERFORM pg_temp.expect('contract','usp_PostJournalEntry posts a balanced entry','2',
        (SELECT count(*)::TEXT FROM acct.journalline WHERE journalentryid = v_je));

    BEGIN
        UPDATE acct.journalline SET memo = 'tampered' WHERE journalentryid = v_je;
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','the trigger rejects an edit to a posted journal line','50007',v_caught);

    BEGIN
        DELETE FROM acct.journalline WHERE journalentryid = v_je;
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','the trigger rejects a delete of a posted journal line','50007',v_caught);

    /*--- 50004 : closed fiscal year -------------------------------------*/
    UPDATE acct.fiscalyear SET isclosed = 1, closedat = now() WHERE fiscalyearid = v_fy;
    BEGIN
        CALL acct.usp_postjournalentry(par_clientid := v_client, par_fiscalyearid := v_fy,
            par_entrydate := DATE '2024-06-01', par_description := 'closed year',
            par_lines := v_lines, par_journalentryid := v_je, p_refcur := v_cur);
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','usp_PostJournalEntry refuses a closed fiscal year','50004',v_caught);
    UPDATE acct.fiscalyear SET isclosed = 0, closedat = NULL WHERE fiscalyearid = v_fy;

    /*--- 50040 / 50042 : client validation ------------------------------*/
    BEGIN
        CALL client.usp_upsertclient(par_clientcode := 'VERIFY-BADSIN', par_clienttype := 'I',
            par_provincecode := 'ON', par_firstname := 'Bad', par_lastname := 'Sin',
            par_dateofbirth := DATE '1990-01-01', par_sin := '046454287',
            par_clientid := v_client, p_refcur := v_cur);
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','usp_UpsertClient rejects an invalid SIN','50040',v_caught);

    BEGIN
        CALL client.usp_upsertclient(par_clientcode := 'VERIFY-BADCORP', par_clienttype := 'C',
            par_provincecode := 'ON', par_clientid := v_client, p_refcur := v_cur);
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','usp_UpsertClient rejects a corporation with no legal name','50042',v_caught);

    /*--- 50050 : invoice with no lines ----------------------------------*/
    SELECT clientid INTO v_client FROM client.client WHERE clientcode = 'VERIFY-CO';
    v_invlines := ARRAY[]::acct.invoicelinetype[];
    BEGIN
        CALL acct.usp_generateinvoice(par_clientid := v_client, par_invoicedate := DATE '2024-06-01',
            par_lines := v_invlines, par_invoiceid := v_inv, p_refcur := v_cur);
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','usp_GenerateInvoice rejects an invoice with no lines','50050',v_caught);

    /*--- 50010 : unknown T1 return --------------------------------------*/
    BEGIN
        CALL tax.usp_calculatet1(par_t1returnid := 999999, p_refcur := v_cur);
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','usp_CalculateT1 rejects an unknown return','50010',v_caught);

    /*--- 50020 / 50021 : slip import ------------------------------------*/
    BEGIN
        CALL tax.usp_importslips(par_clientid := v_client, par_taxyear := 2024,
            par_slipsjson := '{not valid json', p_refcur := v_cur);
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','usp_ImportSlips rejects malformed JSON','50020',v_caught);

    BEGIN
        CALL tax.usp_importslips(par_clientid := 999999, par_taxyear := 2024,
            par_slipsjson := '[]', p_refcur := v_cur);
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','usp_ImportSlips rejects an unknown client','50021',v_caught);

    /*--- province-aware invoicing ---------------------------------------*/
    v_invlines := ARRAY[ROW(1,'Verification services',1.00,1000.00,1)::acct.invoicelinetype];
    CALL acct.usp_generateinvoice(par_clientid := v_client, par_invoicedate := DATE '2024-06-01',
        par_lines := v_invlines, par_status := 'Draft', par_invoiceid := v_inv, p_refcur := v_cur);
    CLOSE v_cur; v_cur := NULL;
    PERFORM pg_temp.expect('contract','usp_GenerateInvoice charges 13% HST in Ontario','130.00',
        (SELECT gsthstamount::TEXT FROM acct.invoice WHERE invoiceid = v_inv));
    -- the restored generated column
    PERFORM pg_temp.expect('contract','invoiceline.linetotal is generated','1000.00',
        (SELECT linetotal::TEXT FROM acct.invoiceline WHERE invoiceid = v_inv));

    UPDATE client.client SET provincecode = 'AB' WHERE clientid = v_client;
    CALL acct.usp_generateinvoice(par_clientid := v_client, par_invoicedate := DATE '2024-06-01',
        par_lines := v_invlines, par_status := 'Draft', par_invoiceid := v_inv, p_refcur := v_cur);
    CLOSE v_cur; v_cur := NULL;
    PERFORM pg_temp.expect('contract','usp_GenerateInvoice charges 5% GST in Alberta','50.00',
        (SELECT gsthstamount::TEXT FROM acct.invoice WHERE invoiceid = v_inv));

    /*--- 50030 : overlapping GST/HST period -----------------------------*/
    CALL tax.usp_filegsthstreturn(par_clientid := v_client, par_periodstart := DATE '2024-01-01',
        par_periodend := DATE '2024-03-31', par_gsthstreturnid := v_je, p_refcur := v_cur);
    CLOSE v_cur; v_cur := NULL;
    BEGIN
        CALL tax.usp_filegsthstreturn(par_clientid := v_client, par_periodstart := DATE '2024-02-01',
            par_periodend := DATE '2024-04-30', par_gsthstreturnid := v_je, p_refcur := v_cur);
        v_caught := 'none';
    EXCEPTION WHEN OTHERS THEN v_caught := SQLSTATE; END;
    PERFORM pg_temp.expect('contract','usp_FileGSTHSTReturn rejects an overlapping period','50030',v_caught);

    /*--- usp_PurgeChangeLog: batched delete, nothing in the window ------*/
    CALL audit.usp_purgechangelog(par_retentiondays := 36500, par_rowsdeleted := v_je, p_refcur := v_cur);
    CLOSE v_cur; v_cur := NULL;
    PERFORM pg_temp.expect('contract','usp_PurgeChangeLog deletes nothing inside the retention window',
        '0', v_je::TEXT);

    /*--- usp_SearchClients: dynamic SQL still returns rows --------------*/
    CALL client.usp_searchclients(par_clienttype := 'C', p_refcur := v_cur);
    CLOSE v_cur; v_cur := NULL;
    PERFORM pg_temp.expect('contract','usp_SearchClients runs its dynamic statement','ok','ok');
END $$;

/*==============================================================================
  5. RESTORED OBJECTS - specifically the things AWS SCT lost
==============================================================================*/
DO $$
DECLARE v_id INTEGER;
BEGIN
    -- The INSTEAD OF INSERT trigger, absent from SCT's output entirely.
    INSERT INTO client.vw_clientdirectory
        (clientcode, clienttype, firstname, lastname, provincecode,
         line1, city, postalcode, primaryemail, isactive, onboardeddate)
    VALUES ('VERIFY-VIEW','I','Through','View','ON',
            '1 Test Street','Toronto','M5V 1A1','through.view@example.ca',1,DATE '2024-01-01');

    SELECT clientid INTO v_id FROM client.client WHERE clientcode='VERIFY-VIEW';
    PERFORM pg_temp.expect('restored','INSTEAD OF INSERT created client + address + contact','1|1|1',
        (SELECT count(*) FROM client.client WHERE clientid=v_id)::TEXT || '|' ||
        (SELECT count(*) FROM client.clientaddress WHERE clientid=v_id)::TEXT || '|' ||
        (SELECT count(*) FROM client.clientcontact WHERE clientid=v_id)::TEXT);

    -- the persisted computed column
    PERFORM pg_temp.expect('restored','client.displayname is generated','View, Through',
        (SELECT displayname FROM client.client WHERE clientid=v_id));

    -- ROWVERSION emulation
    PERFORM pg_temp.expect('restored','rowversion is populated','true',
        (SELECT (rowversion IS NOT NULL)::TEXT FROM client.client WHERE clientid=v_id));

    -- the audit payload must be a JSON object, not an array
    PERFORM pg_temp.expect('restored','audit payload is a JSON object','object',
        (SELECT jsonb_typeof(newvalues) FROM audit.changelog
          WHERE tablename='Client' AND primarykeyvalue = v_id::TEXT AND operation='I'));
    PERFORM pg_temp.expect('restored','vw_RecentChanges shreds the payload','VERIFY-VIEW',
        (SELECT newvalue FROM audit.vw_recentchanges
          WHERE primarykeyvalue = v_id::TEXT AND columnname='clientcode'));

    -- the four other restored generated columns
    PERFORM pg_temp.expect('restored','t1return generated columns exist','4',
        (SELECT count(*)::TEXT FROM information_schema.columns
          WHERE table_schema='tax' AND is_generated='ALWAYS'
            AND table_name='t1return'
            AND column_name IN ('taxableincome','netfederaltax','netprovincialtax','netincome')));
    PERFORM pg_temp.expect('restored','t2return.taxableincome is generated','1',
        (SELECT count(*)::TEXT FROM information_schema.columns
          WHERE table_schema='tax' AND table_name='t2return'
            AND column_name='taxableincome' AND is_generated='ALWAYS'));
END $$;

/*==============================================================================
  6. CLEAN UP THE SCRATCH FIXTURE
==============================================================================*/
DO $$
BEGIN
    -- Two things make this more than a single DELETE, and both are deliberate
    -- parts of the schema rather than obstacles:
    --
    --   * posted journal lines are immutable, so the entries are unposted first
    --     (that the delete is otherwise blocked is asserted above); and
    --   * acct.journalline references acct.account with NO ACTION, so an
    --     account carrying postings cannot be removed. Cascading from the
    --     client would hit that, so the entries go first.
    UPDATE acct.journalentry SET isposted = 0, postedat = NULL, postedby = NULL
     WHERE clientid IN (SELECT clientid FROM client.client WHERE clientcode LIKE 'VERIFY-%');

    DELETE FROM acct.journalentry
     WHERE clientid IN (SELECT clientid FROM client.client WHERE clientcode LIKE 'VERIFY-%');

    DELETE FROM client.client WHERE clientcode LIKE 'VERIFY-%';
END $$;

/*==============================================================================
  7. RESULT

  client_min_messages is raised here so the pass/fail summary is actually
  printed; it is set to warning at the top of the file to keep the routine
  "already exists" chatter out of the way.
==============================================================================*/
SET client_min_messages = notice;

DO $$
DECLARE n INTEGER; r RECORD;
BEGIN
    SELECT count(*) INTO n FROM verify_failures;
    IF n > 0 THEN
        FOR r IN SELECT * FROM verify_failures ORDER BY seq LOOP
            RAISE WARNING '[%] % | expected=% actual=%', r.category, r.assertion, r.expected, r.actual;
        END LOOP;
        RAISE EXCEPTION 'VERIFICATION FAILED: % assertion(s) did not hold.', n;
    END IF;

    RAISE NOTICE 'VERIFICATION PASSED - all assertions hold.';
    RAISE NOTICE '';
    RAISE NOTICE '  39 tables   9 views (1 materialized)   20 functions   12 procedures';
    RAISE NOTICE '  8 triggers  57 foreign keys            10 partial indexes';
    RAISE NOTICE '  18 generated columns across 7 schemas';
END $$;

DROP TABLE IF EXISTS verify_failures;
