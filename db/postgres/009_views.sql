/*==============================================================================
  009 - Views  (PostgreSQL)

  Port of db/sqlserver/009_views.sql. Nine views, listed in the same order as
  the SQL Server file.

  Three needed real work:

    * acct.vw_InvoiceAging   - SCT emitted a (text, error_msg) stub because the
                               original uses PIVOT. Rewritten with FILTER.
    * audit.vw_RecentChanges - stub as well; OPENJSON is not converted
                               (action item 7940). Rewritten with
                               jsonb_each_text over the jsonb payload columns.
    * acct.vw_FiscalYearRevenue - the SQL Server indexed view. SCT flattened it
                               to a plain view, silently dropping the
                               materialization. Restored as a MATERIALIZED VIEW
                               with the unique index REFRESH CONCURRENTLY needs.

  The remaining six came across intact and are kept close to what SCT produced,
  including its LOWER() wrappers emulating SQL Server's case-insensitive
  collation.
==============================================================================*/

SET client_min_messages = warning;

/*------------------------------------------------------------------------------
  Dropped up front so the file is re-runnable. CREATE OR REPLACE VIEW refuses
  any change to the column list, and CREATE MATERIALIZED VIEW has no OR REPLACE
  form at all.
------------------------------------------------------------------------------*/
DROP MATERIALIZED VIEW IF EXISTS acct.vw_fiscalyearrevenue CASCADE;
DROP VIEW IF EXISTS acct.vw_invoiceaging      CASCADE;
DROP VIEW IF EXISTS acct.vw_generalledger     CASCADE;
DROP VIEW IF EXISTS audit.vw_recentchanges    CASCADE;
DROP VIEW IF EXISTS client.vw_clientdirectory CASCADE;
DROP VIEW IF EXISTS payroll.vw_yeartodatepayroll CASCADE;
DROP VIEW IF EXISTS tax.vw_clienttaxprofile   CASCADE;
DROP VIEW IF EXISTS tax.vw_outstandinggsthst  CASCADE;
DROP VIEW IF EXISTS tax.vw_t1returnsummary    CASCADE;



CREATE OR REPLACE  VIEW client.vw_clientdirectory (clientid, clientcode, clienttype, displayname, firstname, lastname, legalname, sin, businessnumber, provincecode, provincename, isactive, onboardeddate, addressid, line1, line2, city, postalcode, primaryemail) AS
/*
--------------------------------------------------------------------------
  1. Client directory - client joined to its primary address.

  This is the target of an INSTEAD OF INSERT trigger (011), which is what lets
  a caller create a client and its address in a single INSERT even though the
  view spans two tables and would otherwise not be insertable.
--------------------------------------------------------------------------
*/
SELECT
    c.clientid, c.clientcode, c.clienttype, c.displayname, c.firstname, c.lastname, c.legalname, c.sin, c.businessnumber, c.provincecode, p.provincename, c.isactive, c.onboardeddate, a.addressid, a.line1, a.line2, a.city, a.postalcode, e.contactvalue AS primaryemail
    FROM client.client AS c
    JOIN ref.province AS p
        ON LOWER(p.provincecode) = LOWER(c.provincecode)
    LEFT OUTER JOIN client.clientaddress AS a
        ON a.clientid = c.clientid AND a.isprimary = 1
    LEFT OUTER JOIN client.clientcontact AS e
        ON e.clientid = c.clientid AND e.isprimary = 1 AND LOWER(e.contacttype) = LOWER('Email');

CREATE OR REPLACE  VIEW tax.vw_t1returnsummary (t1returnid, clientid, clientcode, displayname, taxyear, provinceofresidence, filingstatus, totalincome, totaldeductions, netincome, taxableincome, assessedfederaltax, recalculatedfederaltax, federaltaxvariance, assessedprovincialtax, recalculatedprovincialtax, provincialtaxvariance, netfederaltax, netprovincialtax, marginalrate, averagerate, taxwithheld, installmentspaid, totalpayable, balanceowing, datefiled, calculatedat, assessedat) AS
/*
--------------------------------------------------------------------------
  2. T1 summary - the assessed figures side by side with a live recalculation.

  A non-zero variance means the stored assessment no longer agrees with the
  rate tables, which is exactly the condition tax.usp_RecalculateAllReturns
  exists to clear.
--------------------------------------------------------------------------
*/
SELECT
    r.t1returnid, r.clientid, c.clientcode, c.displayname, r.taxyear, r.provinceofresidence, r.filingstatus, r.totalincome, r.totaldeductions, r.netincome, r.taxableincome, r.federaltax AS assessedfederaltax, tax.fn_federaltax(r.taxyear, r.taxableincome) AS recalculatedfederaltax, r.federaltax - tax.fn_federaltax(r.taxyear, r.taxableincome) AS federaltaxvariance, r.provincialtax AS assessedprovincialtax, tax.fn_provincialtax(r.provinceofresidence, r.taxyear, r.taxableincome) AS recalculatedprovincialtax, r.provincialtax - tax.fn_provincialtax(r.provinceofresidence, r.taxyear, r.taxableincome) AS provincialtaxvariance, r.netfederaltax, r.netprovincialtax, tax.fn_marginalrate(r.provinceofresidence, r.taxyear, r.taxableincome) AS marginalrate,
    /* Average rate on taxable income; NULLIF keeps a zero-income return */
    /* from raising a divide-by-zero. */
    CAST ((r.netfederaltax + r.netprovincialtax) / NULLIF(r.taxableincome, 0) AS NUMERIC(9, 6)) AS averagerate, r.taxwithheld, r.installmentspaid, r.totalpayable, r.balanceowing, r.datefiled, r.calculatedat, r.assessedat
    FROM tax.t1return AS r
    JOIN client.client AS c
        ON c.clientid = r.clientid;

CREATE OR REPLACE  VIEW tax.vw_outstandinggsthst (gsthstreturnid, clientid, clientcode, displayname, businessnumber, periodstart, periodend, filingfrequency, line101sales, line105taxcollected, line108inputtaxcredits, line109nettax, paymentsmade, balancedue, filingduedate, filedat, status, dayspastdue, situation) AS
/*
--------------------------------------------------------------------------
  3. GST/HST returns that are unfiled or still carry a balance.
--------------------------------------------------------------------------
*/
SELECT
    g.gsthstreturnid, g.clientid, c.clientcode, c.displayname, c.businessnumber, g.periodstart, g.periodend, f.description AS filingfrequency, g.line101sales, g.line105taxcollected, g.line108inputtaxcredits, g.line109nettax, g.paymentsmade, g.balancedue, g.filingduedate, g.filedat, g.status, ((((timezone('UTC', LOCALTIMESTAMP(6)))::date))::date - (g.filingduedate)::date) AS dayspastdue,
    CASE
        WHEN g.filedat IS NULL THEN 'Not filed'
        WHEN g.balancedue > 0 THEN 'Filed, balance owing'
        ELSE 'Filed, refund due'
    END AS situation
    FROM tax.gsthstreturn AS g
    JOIN client.client AS c
        ON c.clientid = g.clientid
    JOIN ref.filingfrequency AS f
        ON LOWER(f.frequencycode) = LOWER(g.frequencycode)
    WHERE g.filedat IS NULL OR g.balancedue <> 0;

CREATE OR REPLACE VIEW acct.vw_invoiceaging AS
/*
  4. Receivables aged into buckets, one row per client.

  AWS SCT could not convert this at all and emitted a (text, error_msg) stub,
  because the SQL Server original is built with PIVOT. PostgreSQL has no PIVOT;
  the portable equivalent is conditional aggregation, and FILTER (WHERE ...)
  expresses it directly.

  Like the original this is "as at today", so it is a reporting view rather
  than a deterministic one - assertions against it must be structural.
*/
SELECT ag.clientid,
       c.clientcode,
       c.displayname,
       COALESCE(SUM(ag.outstandingamount) FILTER (WHERE ag.agingbucket = 'Current'), 0) AS currentamount,
       COALESCE(SUM(ag.outstandingamount) FILTER (WHERE ag.agingbucket = '1-30'),    0) AS days1to30,
       COALESCE(SUM(ag.outstandingamount) FILTER (WHERE ag.agingbucket = '31-60'),   0) AS days31to60,
       COALESCE(SUM(ag.outstandingamount) FILTER (WHERE ag.agingbucket = '61-90'),   0) AS days61to90,
       COALESCE(SUM(ag.outstandingamount) FILTER (WHERE ag.agingbucket = '90+'),     0) AS days90plus,
       COALESCE(SUM(ag.outstandingamount), 0)                                          AS totaloutstanding
  FROM acct.fn_invoiceaging((timezone('UTC', now()))::date) AS ag
  JOIN client.client AS c ON c.clientid = ag.clientid
 GROUP BY ag.clientid, c.clientcode, c.displayname;

CREATE OR REPLACE  VIEW acct.vw_generalledger (clientid, fiscalyearid, journalentryid, entrynumber, entrydate, description, source, journallineid, linenumber, accountid, accountnumber, accountname, normalbalance, debitamount, creditamount, memo, runningdebitbalance, accountlinesequence) AS
/*
--------------------------------------------------------------------------
  5. General ledger with a per-account running balance.

  The window frame is explicit: without ROWS BETWEEN ... CURRENT ROW the
  default frame is RANGE, which would lump together every line sharing an
  entry date and give the wrong running total.
--------------------------------------------------------------------------
*/
SELECT
    e.clientid, e.fiscalyearid, e.journalentryid, e.entrynumber, e.entrydate, e.description, e.source, l.journallineid, l.linenumber, a.accountid, a.accountnumber, a.accountname, t.normalbalance, l.debitamount, l.creditamount, l.memo, SUM(l.debitamount - l.creditamount) OVER (PARTITION BY a.accountid ORDER BY e.entrydate, e.journalentryid, l.linenumber ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS runningdebitbalance, ROW_NUMBER() OVER (PARTITION BY a.accountid ORDER BY e.entrydate, e.journalentryid, l.linenumber) AS accountlinesequence
    FROM acct.journalentry AS e
    JOIN acct.journalline AS l
        ON l.journalentryid = e.journalentryid
    JOIN acct.account AS a
        ON a.accountid = l.accountid
    JOIN ref.accounttype AS t
        ON LOWER(t.accounttypecode) = LOWER(a.accounttypecode)
    WHERE e.isposted = 1;

CREATE MATERIALIZED VIEW acct.vw_fiscalyearrevenue (clientid, fiscalyearid, accounttypecode, totalcredits, totaldebits, linecount) AS
/*
--------------------------------------------------------------------------
  6. INDEXED VIEW - revenue and expense totals per client per fiscal year.

  The rules this has to satisfy are why it looks so plain: SCHEMABINDING with
  two-part names, inner joins only, no subqueries or outer joins, no DISTINCT,
  and COUNT_BIG(*) present alongside the aggregates. The result is physically
  materialized by the unique clustered index that follows.
--------------------------------------------------------------------------
*/
SELECT
    e.clientid, e.fiscalyearid, t.accounttypecode, SUM(l.creditamount) AS totalcredits, SUM(l.debitamount) AS totaldebits, COUNT(*) AS linecount
    FROM acct.journalentry AS e
    JOIN acct.journalline AS l
        ON l.journalentryid = e.journalentryid
    JOIN acct.account AS a
        ON a.accountid = l.accountid
    JOIN ref.accounttype AS t
        ON LOWER(t.accounttypecode) = LOWER(a.accounttypecode)
    WHERE e.isposted = 1 AND t.isnominal = 1
    GROUP BY e.clientid, e.fiscalyearid, t.accounttypecode;

/*
  SQL Server maintains an indexed view transparently on every write. PostgreSQL
  does not: a materialized view is a snapshot that has to be refreshed. The
  unique index below is what allows REFRESH ... CONCURRENTLY, and it is also the
  direct analogue of the unique clustered index the SQL Server version needs in
  order to exist at all.

  Callers that write to acct.journalline must refresh it - acct.usp_PostJournalEntry
  and acct.usp_CloseFiscalYear do. This is a real behavioural difference between
  the two ports, not an oversight.
*/
CREATE UNIQUE INDEX ucx_vw_fiscalyearrevenue
    ON acct.vw_fiscalyearrevenue (clientid, fiscalyearid, accounttypecode);

CREATE OR REPLACE  VIEW payroll.vw_yeartodatepayroll (clientid, taxyear, payperiodid, periodnumber, paydate, employeeid, employeenumber, lastname, firstname, provinceofemployment, grosspay, cppdeducted, cpp2deducted, eideducted, federaltaxdeducted, provincialtaxdeducted, netpay, ytdgrosspay, ytdcpp, ytdei, ytdincometax, ytdnetpay) AS
/*
--------------------------------------------------------------------------
  7. Payroll with year-to-date running totals per employee.

  YTD figures matter because CPP and EI both stop once an employee reaches the
  annual maximum, so the running totals are what a correct payroll run reads.
--------------------------------------------------------------------------
*/
SELECT
    pp.clientid, pp.taxyear, pp.payperiodid, pp.periodnumber, pp.paydate, emp.employeeid, emp.employeenumber, emp.lastname, emp.firstname, emp.provinceofemployment, ps.grosspay, ps.cppdeducted, ps.cpp2deducted, ps.eideducted, ps.federaltaxdeducted, ps.provincialtaxdeducted, ps.netpay, SUM(ps.grosspay) OVER (PARTITION BY emp.employeeid, pp.taxyear ORDER BY pp.periodnumber ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ytdgrosspay, SUM(ps.cppdeducted + ps.cpp2deducted) OVER (PARTITION BY emp.employeeid, pp.taxyear ORDER BY pp.periodnumber ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ytdcpp, SUM(ps.eideducted) OVER (PARTITION BY emp.employeeid, pp.taxyear ORDER BY pp.periodnumber ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ytdei, SUM(ps.federaltaxdeducted + ps.provincialtaxdeducted) OVER (PARTITION BY emp.employeeid, pp.taxyear ORDER BY pp.periodnumber ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ytdincometax, SUM(ps.netpay) OVER (PARTITION BY emp.employeeid, pp.taxyear ORDER BY pp.periodnumber ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ytdnetpay
    FROM payroll.paystub AS ps
    JOIN payroll.payperiod AS pp
        ON pp.payperiodid = ps.payperiodid
    JOIN payroll.employee AS emp
        ON emp.employeeid = ps.employeeid;

CREATE OR REPLACE  VIEW tax.vw_clienttaxprofile (clientid, clientcode, displayname, clienttype, provincecode, provincename, isactive, currentsalestaxrate, latesttaxyear, latesttaxableincome, latestbalanceowing, returncount, slipcount, outstandingreceivable, unfiledgsthstreturns, gsthstbalancedue, openengagements) AS
/*
--------------------------------------------------------------------------
  8. One row per client pulling together every domain: filings, slips,
  receivables and sales tax. This is the view a practice dashboard would bind
  to, and the widest cross-schema read in the schema.
--------------------------------------------------------------------------
*/
SELECT
    c.clientid, c.clientcode, c.displayname, c.clienttype, c.provincecode, p.provincename, c.isactive, ref.fn_salestaxrate(c.provincecode, ((timezone('UTC', LOCALTIMESTAMP(6)))::date)) AS currentsalestaxrate, t1.latesttaxyear, t1.latesttaxableincome, t1.latestbalanceowing, t1.returncount, sl.slipcount, ar.outstandingreceivable, gst.unfiledgsthstreturns, gst.gsthstbalancedue, eng.openengagements
    FROM client.client AS c
    JOIN ref.province AS p
        ON LOWER(p.provincecode) = LOWER(c.provincecode)
    LEFT JOIN LATERAL (SELECT
        COUNT(*) AS returncount, MAX(r.taxyear) AS latesttaxyear,
        /* The figures for the most recent year only. */
        MAX(CASE
            WHEN r.taxyear = mr.maxyear THEN r.taxableincome
        END) AS latesttaxableincome, MAX(CASE
            WHEN r.taxyear = mr.maxyear THEN r.balanceowing
        END) AS latestbalanceowing
        FROM tax.t1return AS r
        CROSS JOIN LATERAL (SELECT
            MAX(r2.taxyear) AS maxyear
            FROM tax.t1return AS r2
            WHERE r2.clientid = c.clientid) AS mr
        WHERE r.clientid = c.clientid) AS t1 ON true
    LEFT JOIN LATERAL (SELECT
        COUNT(*) AS slipcount
        FROM tax.slip AS s
        WHERE s.clientid = c.clientid) AS sl ON true
    LEFT JOIN LATERAL (SELECT
        COALESCE(SUM(ag.outstandingamount), 0) AS outstandingreceivable
        FROM acct.fn_invoiceaging(((timezone('UTC', LOCALTIMESTAMP(6)))::date))
            AS ag
        WHERE ag.clientid = c.clientid) AS ar ON true
    LEFT JOIN LATERAL (SELECT
        SUM(CASE
            WHEN g.filedat IS NULL THEN 1
            ELSE 0
        END) AS unfiledgsthstreturns, COALESCE(SUM(g.balancedue), 0) AS gsthstbalancedue
        FROM tax.gsthstreturn AS g
        WHERE g.clientid = c.clientid) AS gst ON true
    LEFT JOIN LATERAL (SELECT
        COUNT(*) AS openengagements
        FROM client.engagement AS en
        WHERE en.clientid = c.clientid AND LOWER(en.status) IN (LOWER('Open'), LOWER('InProgress'), LOWER('AwaitingClient'))) AS eng ON true;

CREATE OR REPLACE VIEW audit.vw_recentchanges AS
/*
  9. Audit log shredded to one row per changed column.

  The other view AWS SCT emitted as a stub: it cannot convert OPENJSON
  (action item 7940). audit.changelog.oldvalues / newvalues are jsonb here, so
  jsonb_each_text expands an object into key/value rows directly - the exact
  analogue of OPENJSON's [key]/[value].

  LEFT JOIN LATERAL ... ON true reproduces OUTER APPLY: a delete has no
  newvalues, and the row still appears rather than vanishing.
*/
SELECT cl.changelogid,
       cl.schemaname,
       cl.tablename,
       cl.primarykeyvalue,
       cl.operation,
       cl.changedby,
       cl.changedat,
       COALESCE(nv.key, ov.key) AS columnname,
       ov.value                 AS oldvalue,
       nv.value                 AS newvalue,
       -- PostgreSQL has a boolean type, but this stays 0/1 so the column reads
       -- identically to the SQL Server view.
       CASE WHEN cl.operation <> 'U'                          THEN 0
            WHEN ov.value IS NULL AND nv.value IS NULL        THEN 0
            WHEN ov.value IS NULL OR  nv.value IS NULL        THEN 1
            WHEN ov.value <> nv.value                         THEN 1
            ELSE 0
       END                      AS ischanged
  FROM audit.changelog AS cl
  LEFT JOIN LATERAL jsonb_each_text(cl.newvalues) AS nv(key, value) ON true
  LEFT JOIN LATERAL (
           SELECT o.key, o.value
             FROM jsonb_each_text(cl.oldvalues) AS o(key, value)
            WHERE o.key = nv.key
       ) AS ov ON true;
