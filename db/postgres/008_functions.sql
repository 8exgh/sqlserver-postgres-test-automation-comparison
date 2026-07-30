/*==============================================================================
  008 - Functions  (PostgreSQL)

  Port of db/sqlserver/008_functions.sql: 15 scalar, 3 inline table-valued and
  2 multi-statement table-valued functions.

  This is the one area AWS SCT handled well - the bodies came across intact,
  including WITH RECURSIVE in fn_AccountHierarchy - so they are kept close to
  what it produced. Two things it did not do:

    * No volatility markers, so every function defaulted to VOLATILE and the
      planner would neither inline nor cache any of them. The three pure
      validators are marked IMMUTABLE; everything else reads tables and is
      marked STABLE.

    * It also emitted three <type>$aws$f helpers that create a temp table per
      table-valued parameter. The procedures here take composite arrays
      instead, so those are dropped.

  SQL Server BIT return values stay as 0/1 numerics rather than becoming
  boolean, so assertions read identically against both engines.

  A note on parameter types: SQL Server declares TaxYear as SMALLINT, and SCT
  carried that into the function signatures. PostgreSQL will not implicitly
  narrow an integer literal to smallint during function resolution, so
  tax.fn_FederalTax(2024, 100000) failed to resolve at all and every call site
  would have needed 2024::smallint. The parameters are widened to INTEGER here
  so an identical call works against both engines - which is the whole point of
  keeping the two schemas comparable.

==============================================================================*/

SET client_min_messages = warning;

/*------------------------------------------------------------------------------
  CREATE OR REPLACE keeps an old overload alive when a signature changes, and
  the next call then fails with 42725 (ambiguous). Dropping by name first
  makes re-applying this file clean.
------------------------------------------------------------------------------*/
DROP FUNCTION IF EXISTS acct.fn_accountbalance CASCADE;
DROP FUNCTION IF EXISTS acct.fn_accounthierarchy CASCADE;
DROP FUNCTION IF EXISTS acct.fn_invoiceaging CASCADE;
DROP FUNCTION IF EXISTS acct.fn_trialbalance CASCADE;
DROP FUNCTION IF EXISTS ref.fn_gsthstrate CASCADE;
DROP FUNCTION IF EXISTS ref.fn_pstrate CASCADE;
DROP FUNCTION IF EXISTS ref.fn_salestaxrate CASCADE;
DROP FUNCTION IF EXISTS tax.fn_brackettax CASCADE;
DROP FUNCTION IF EXISTS tax.fn_clientsliptotals CASCADE;
DROP FUNCTION IF EXISTS tax.fn_cpp2contribution CASCADE;
DROP FUNCTION IF EXISTS tax.fn_cppcontribution CASCADE;
DROP FUNCTION IF EXISTS tax.fn_eipremium CASCADE;
DROP FUNCTION IF EXISTS tax.fn_federaltax CASCADE;
DROP FUNCTION IF EXISTS tax.fn_isvalidbusinessnumber CASCADE;
DROP FUNCTION IF EXISTS tax.fn_isvalidsin CASCADE;
DROP FUNCTION IF EXISTS tax.fn_marginalrate CASCADE;
DROP FUNCTION IF EXISTS tax.fn_provincialtax CASCADE;
DROP FUNCTION IF EXISTS tax.fn_taxbracketbreakdown CASCADE;
DROP FUNCTION IF EXISTS util.fn_businessdaysbetween CASCADE;
DROP FUNCTION IF EXISTS util.fn_passesluhn CASCADE;


CREATE OR REPLACE FUNCTION acct.fn_accountbalance(IN par_accountid INTEGER, IN par_asofdate DATE)
RETURNS NUMERIC
AS
$BODY$
/*
==============================================================================
  SCALAR - accounting and dates
==============================================================================
*/
/*
--------------------------------------------------------------------------
  Balance of a single account as at a date, signed by the account type's
  normal balance so an asset and a liability both read as positive when they
  are in their expected direction. Only posted entries count.
--------------------------------------------------------------------------
*/
DECLARE
    var_debits NUMERIC(19, 2);
    var_credits NUMERIC(19, 2);
    var_normal CHAR(1);
BEGIN
    SELECT
        t.normalbalance
        INTO var_normal
        FROM acct.account AS a
        JOIN ref.accounttype AS t
            ON LOWER(t.accounttypecode) = LOWER(a.accounttypecode)
        WHERE a.accountid = par_AccountId;

    IF var_normal IS NULL THEN
        RETURN 0;
    END IF;
    SELECT
        COALESCE(SUM(l.debitamount), 0), COALESCE(SUM(l.creditamount), 0)
        INTO var_debits, var_credits
        FROM acct.journalline AS l
        JOIN acct.journalentry AS e
            ON e.journalentryid = l.journalentryid
        WHERE l.accountid = par_AccountId AND e.isposted = 1 AND e.entrydate <= par_AsOfDate;
    RETURN
    CASE
        WHEN LOWER(var_normal) = LOWER('D') THEN COALESCE(var_debits, 0) - COALESCE(var_credits, 0)
        ELSE COALESCE(var_credits, 0) - COALESCE(var_debits, 0)
    END;
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION acct.fn_accounthierarchy(IN par_clientid INTEGER, IN par_rootaccountid INTEGER)
RETURNS TABLE (accountid INTEGER, parentaccountid INTEGER, accountnumber VARCHAR, accountname VARCHAR, accounttypecode VARCHAR, depth INTEGER, namepath VARCHAR, sortpath VARCHAR)
AS
$BODY$
/*
--------------------------------------------------------------------------
  Walks the chart of accounts from a root (or from every top-level account
  when @RootAccountId is NULL), returning depth and a materialized path.

  SortPath is the account-number path, which sorts the tree into the order a
  human expects to read it in.
--------------------------------------------------------------------------
*/
BEGIN
    -- Same change as fn_TrialBalance: SCT staged the recursive CTE through a
    -- temp table, which made the function unable to be STABLE. The CTE is
    -- returned directly instead.
    RETURN QUERY
    WITH RECURSIVE tree AS (
        SELECT a.accountid,
               a.parentaccountid,
               a.accountnumber,
               a.accountname,
               a.accounttypecode,
               0                                          AS depth,
               CAST(a.accountname   AS VARCHAR(4000))     AS namepath,
               CAST(a.accountnumber AS VARCHAR(4000))     AS sortpath
          FROM acct.account AS a
         WHERE a.clientid = par_ClientId
           AND ((par_RootAccountId IS NULL AND a.parentaccountid IS NULL)
             OR (a.accountid = par_RootAccountId))
        UNION ALL
        SELECT child.accountid,
               child.parentaccountid,
               child.accountnumber,
               child.accountname,
               child.accounttypecode,
               parent.depth + 1,
               CAST(parent.namepath || ' > ' || child.accountname   AS VARCHAR(4000)),
               CAST(parent.sortpath || '.'   || child.accountnumber AS VARCHAR(4000))
          FROM acct.account AS child
          JOIN tree         AS parent ON parent.accountid = child.parentaccountid
         WHERE child.clientid = par_ClientId
    )
    SELECT t.accountid,
           t.parentaccountid,
           t.accountnumber::VARCHAR,
           t.accountname::VARCHAR,
           t.accounttypecode::VARCHAR,
           t.depth,
           t.namepath::VARCHAR,
           t.sortpath::VARCHAR
      FROM tree AS t;
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION acct.fn_invoiceaging(IN par_asofdate DATE)
RETURNS TABLE (invoiceid INTEGER, invoicenumber INTEGER, clientid INTEGER, invoicedate DATE, duedate DATE, total NUMERIC, outstandingamount NUMERIC, daysoverdue INTEGER, agingbucket VARCHAR)
AS
$BODY$
/*
--------------------------------------------------------------------------
  Outstanding receivables bucketed by age. Returns only invoices with a
  positive balance so the caller does not have to filter.
--------------------------------------------------------------------------
*/
# variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT
        i.invoiceid, i.invoicenumber, i.clientid, i.invoicedate, i.duedate, i.total, i.total - COALESCE(p.amountpaid, 0) AS outstandingamount, ((par_AsOfDate)::date - (i.duedate)::date) AS daysoverdue,
        CASE
            WHEN ((par_AsOfDate)::date - (i.duedate)::date) <= 0 THEN 'Current'
            WHEN ((par_AsOfDate)::date - (i.duedate)::date) <= 30 THEN '1-30'
            WHEN ((par_AsOfDate)::date - (i.duedate)::date) <= 60 THEN '31-60'
            WHEN ((par_AsOfDate)::date - (i.duedate)::date) <= 90 THEN '61-90'
            ELSE '90+'
        -- PostgreSQL matches RETURN QUERY columns against the RETURNS TABLE
        -- declaration by exact type. A bare CASE over string literals is text,
        -- not varchar, so without this cast the function compiles but fails at
        -- run time with "structure of query does not match function result
        -- type".
        END::VARCHAR AS agingbucket
        FROM acct.invoice AS i
        LEFT OUTER JOIN LATERAL (SELECT
            SUM(pay.amount) AS amountpaid
            FROM acct.payment AS pay
            WHERE pay.invoiceid = i.invoiceid AND pay.paymentdate <= par_AsOfDate) AS p
            ON true
        WHERE LOWER(i.status) IN (LOWER('Sent'), LOWER('PartiallyPaid')) AND i.invoicedate <= par_AsOfDate AND i.total - COALESCE(p.amountpaid, 0) > 0;
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION acct.fn_trialbalance(IN par_clientid INTEGER, IN par_fiscalyearid INTEGER, IN par_asofdate DATE)
RETURNS TABLE (accountid INTEGER, accountnumber VARCHAR, accountname VARCHAR, accounttypecode VARCHAR, normalbalance CHAR, totaldebits NUMERIC, totalcredits NUMERIC, balance NUMERIC, istotalrow NUMERIC)
AS
$BODY$
/*
==============================================================================
  MULTI-STATEMENT TABLE-VALUED FUNCTIONS
==============================================================================
*/
/*
--------------------------------------------------------------------------
  Trial balance for a fiscal year as at a date. Multi-statement because the
  final row is a total line that has to be appended after the per-account
  aggregate is known.
--------------------------------------------------------------------------
*/
BEGIN
    -- AWS SCT implements this by creating a temp table, inserting the
    -- per-account rows, inserting a total row that reads them back, then
    -- selecting the lot. That forces the function to be VOLATILE (DROP TABLE is
    -- not allowed in a STABLE function) and churns a temp table on every call.
    --
    -- A CTE expresses the same thing directly: aggregate once, then UNION the
    -- total row computed from it. Same result, no temp table, STABLE.
    RETURN QUERY
    WITH per_account AS (
        SELECT a.accountid,
               a.accountnumber,
               a.accountname,
               a.accounttypecode,
               t.normalbalance,
               SUM(l.debitamount)  AS totaldebits,
               SUM(l.creditamount) AS totalcredits,
               CASE WHEN LOWER(t.normalbalance) = LOWER('D')
                    THEN SUM(l.debitamount) - SUM(l.creditamount)
                    ELSE SUM(l.creditamount) - SUM(l.debitamount)
               END                 AS balance
          FROM acct.account      AS a
          JOIN ref.accounttype   AS t ON LOWER(t.accounttypecode) = LOWER(a.accounttypecode)
          JOIN acct.journalline  AS l ON l.accountid = a.accountid
          JOIN acct.journalentry AS e ON e.journalentryid = l.journalentryid
         WHERE a.clientid     = par_ClientId
           AND e.fiscalyearid = par_FiscalYearId
           AND e.isposted     = 1
           AND e.entrydate   <= par_AsOfDate
         GROUP BY a.accountid, a.accountnumber, a.accountname,
                  a.accounttypecode, t.normalbalance
    )
    SELECT pa.accountid,
           pa.accountnumber::VARCHAR,
           pa.accountname::VARCHAR,
           pa.accounttypecode::VARCHAR,
           pa.normalbalance::CHAR,
           pa.totaldebits::NUMERIC,
           pa.totalcredits::NUMERIC,
           pa.balance::NUMERIC,
           0::NUMERIC AS istotalrow
      FROM per_account AS pa
    UNION ALL
    -- The total row: in a balanced ledger the two columns must be equal, which
    -- is what makes this function a useful assertion target.
    SELECT NULL::INTEGER,
           'ZZZZ'::VARCHAR,
           'TOTAL'::VARCHAR,
           NULL::VARCHAR,
           NULL::CHAR,
           COALESCE(SUM(pa.totaldebits), 0)::NUMERIC,
           COALESCE(SUM(pa.totalcredits), 0)::NUMERIC,
           (COALESCE(SUM(pa.totaldebits), 0) - COALESCE(SUM(pa.totalcredits), 0))::NUMERIC,
           1::NUMERIC
      FROM per_account AS pa;
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION ref.fn_gsthstrate(IN par_provincecode CHAR, IN par_asofdate DATE)
RETURNS NUMERIC
AS
$BODY$
/*
==============================================================================
  SCALAR - sales tax
==============================================================================
*/
/*
--------------------------------------------------------------------------
  The GST/HST portion only - what a registrant collects and remits to the CRA.
--------------------------------------------------------------------------
*/
DECLARE
    var_rate NUMERIC(9, 5);
BEGIN
    -- AWS SCT rendered the T-SQL "SELECT @rate = <expr> FROM ..." assignment as
    -- SELECT STRING_AGG(col1, '') FROM (SELECT <expr> AS col1 INTO var_rate ...),
    -- which is broken twice: STRING_AGG has no numeric overload, and the INTO
    -- ended up nested inside the subquery where it does nothing. The direct
    -- SELECT ... INTO below is the correct equivalent.
    SELECT r.gstrate + r.hstrate
      INTO var_rate
      FROM ref.salestaxrate AS r
     WHERE LOWER(r.provincecode) = LOWER(par_ProvinceCode)
       AND r.effectivefrom <= par_AsOfDate
       AND (r.effectiveto IS NULL OR r.effectiveto > par_AsOfDate);
    RETURN COALESCE(var_rate, 0);
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION ref.fn_pstrate(IN par_provincecode CHAR, IN par_asofdate DATE)
RETURNS NUMERIC
AS
$BODY$
/*
--------------------------------------------------------------------------
  The provincial portion (PST, or QST in Quebec), which is remitted to the
  province rather than to the CRA.
--------------------------------------------------------------------------
*/
DECLARE
    var_rate NUMERIC(9, 5);
BEGIN
    -- AWS SCT rendered the T-SQL "SELECT @rate = <expr> FROM ..." assignment as
    -- SELECT STRING_AGG(col1, '') FROM (SELECT <expr> AS col1 INTO var_rate ...),
    -- which is broken twice: STRING_AGG has no numeric overload, and the INTO
    -- ended up nested inside the subquery where it does nothing. The direct
    -- SELECT ... INTO below is the correct equivalent.
    SELECT r.pstrate + r.qstrate
      INTO var_rate
      FROM ref.salestaxrate AS r
     WHERE LOWER(r.provincecode) = LOWER(par_ProvinceCode)
       AND r.effectivefrom <= par_AsOfDate
       AND (r.effectiveto IS NULL OR r.effectiveto > par_AsOfDate);
    RETURN COALESCE(var_rate, 0);
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION ref.fn_salestaxrate(IN par_provincecode CHAR, IN par_asofdate DATE)
RETURNS NUMERIC
AS
$BODY$
BEGIN
    RETURN ref.fn_gsthstrate(par_ProvinceCode, par_AsOfDate) + ref.fn_pstrate(par_ProvinceCode, par_AsOfDate);
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION tax.fn_brackettax(IN par_jurisdictioncode CHAR, IN par_taxyear INTEGER, IN par_taxableincome NUMERIC)
RETURNS NUMERIC
AS
$BODY$
/*
==============================================================================
  SCALAR - income tax
==============================================================================
*/
/*
--------------------------------------------------------------------------
  Progressive tax for any jurisdiction. Each bracket contributes
  (min(income, upper) - lower) * rate for the portion of income above its
  lower bound; the top bracket has a NULL upper bound.

  fn_FederalTax and fn_ProvincialTax are thin wrappers so callers never have
  to know that the federal jurisdiction code is 'CA'.
--------------------------------------------------------------------------
*/
DECLARE
    var_tax NUMERIC(29, 8);
BEGIN
    IF par_TaxableIncome IS NULL OR par_TaxableIncome <= 0 THEN
        RETURN 0;
    END IF;
    SELECT
        SUM((CASE
            WHEN b.upperbound IS NOT NULL AND par_TaxableIncome > b.upperbound THEN b.upperbound
            ELSE par_TaxableIncome
        END - b.lowerbound) * b.rate)
        INTO var_tax
        FROM ref.taxbracket AS b
        WHERE LOWER(b.jurisdictioncode) = LOWER(par_JurisdictionCode) AND b.taxyear = par_TaxYear AND par_TaxableIncome > b.lowerbound;
    RETURN CAST (ROUND(COALESCE(var_tax, 0), 2) AS NUMERIC(19, 2));
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION tax.fn_clientsliptotals(IN par_clientid INTEGER, IN par_taxyear INTEGER)
RETURNS TABLE (employmentincome NUMERIC, investmentincome NUMERIC, selfemploymentincome NUMERIC, pensionincome NUMERIC, otherincome NUMERIC, deductions NUMERIC, taxwithheld NUMERIC, cppcontributions NUMERIC, eipremiums NUMERIC, slipcount BIGINT)
AS
$BODY$
/*
--------------------------------------------------------------------------
  Slip amounts rolled up into the income lines they feed on a T1. This is what
  makes the box/definition mapping in ref.SlipBoxDefinition earn its keep: a
  T4 box 14 and a T4A box 020 both land in the right place without the caller
  knowing either box number.
--------------------------------------------------------------------------
*/
BEGIN
    RETURN QUERY
    SELECT
        COALESCE(SUM(CASE
            WHEN LOWER(d.incomecategory) = LOWER('Employment') THEN sb.amount
        END), 0) AS employmentincome, COALESCE(SUM(CASE
            WHEN LOWER(d.incomecategory) = LOWER('Investment') THEN sb.amount
        END), 0) AS investmentincome, COALESCE(SUM(CASE
            WHEN LOWER(d.incomecategory) = LOWER('SelfEmployment') THEN sb.amount
        END), 0) AS selfemploymentincome, COALESCE(SUM(CASE
            WHEN LOWER(d.incomecategory) = LOWER('Pension') THEN sb.amount
        END), 0) AS pensionincome, COALESCE(SUM(CASE
            WHEN LOWER(d.incomecategory) = LOWER('Other') THEN sb.amount
        END), 0) AS otherincome, COALESCE(SUM(CASE
            WHEN LOWER(d.incomecategory) = LOWER('Deduction') THEN sb.amount
        END), 0) AS deductions, COALESCE(SUM(CASE
            WHEN LOWER(d.incomecategory) = LOWER('TaxWithheld') THEN sb.amount
        END), 0) AS taxwithheld, COALESCE(SUM(CASE
            WHEN LOWER(d.incomecategory) = LOWER('CPP') THEN sb.amount
        END), 0) AS cppcontributions, COALESCE(SUM(CASE
            WHEN LOWER(d.incomecategory) = LOWER('EI') THEN sb.amount
        END), 0) AS eipremiums, COUNT(DISTINCT s.slipid) AS slipcount
        FROM tax.slip AS s
        JOIN tax.slipbox AS sb
            ON sb.slipid = s.slipid
        JOIN ref.slipboxdefinition AS d
            ON LOWER(d.sliptypecode) = LOWER(sb.sliptypecode) AND LOWER(d.boxnumber) = LOWER(sb.boxnumber)
        WHERE s.clientid = par_ClientId AND s.taxyear = par_TaxYear;
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION tax.fn_cpp2contribution(IN par_taxyear INTEGER, IN par_pensionableearnings NUMERIC)
RETURNS NUMERIC
AS
$BODY$
/*
--------------------------------------------------------------------------
  CPP2: the second additional contribution on earnings between the YMPE and
  the YAMPE. Returns zero for years before it existed (YAMPE seeded as 0).
--------------------------------------------------------------------------
*/
DECLARE
    var_rate NUMERIC(9, 6);
    var_ympe NUMERIC(19, 2);
    var_yampe NUMERIC(19, 2);
    var_contributory NUMERIC(19, 2);
BEGIN
    IF par_PensionableEarnings IS NULL OR par_PensionableEarnings <= 0 THEN
        RETURN 0;
    END IF;
    SELECT
        p.cpp2rate, p.ympe, p.yampe
        INTO var_rate, var_ympe, var_yampe
        FROM ref.payrollrate AS p
        WHERE p.taxyear = par_TaxYear;

    IF var_rate IS NULL OR var_rate = 0 OR var_yampe IS NULL OR var_yampe <= var_ympe THEN
        RETURN 0;
    END IF;

    IF par_PensionableEarnings <= var_ympe THEN
        RETURN 0;
    END IF;

    -- AWS SCT hoisted the T-SQL "DECLARE @x DECIMAL(19,2) = <expr>;" into a
    -- PL/pgSQL DECLARE ... DEFAULT. That changes when the expression runs:
    -- DECLARE defaults are evaluated on block entry, before the SELECT below
    -- has loaded the rate row, so the variable was computed from NULLs. In
    -- T-SQL the same statement sits *after* the SELECT. Assigning it here
    -- restores the original order of evaluation.
    var_contributory := (CASE
        WHEN par_PensionableEarnings > var_yampe THEN var_yampe
        ELSE par_PensionableEarnings
    END) - var_ympe;
    RETURN CAST (ROUND(var_contributory * var_rate, 2) AS NUMERIC(19, 2));
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION tax.fn_cppcontribution(IN par_taxyear INTEGER, IN par_pensionableearnings NUMERIC)
RETURNS NUMERIC
AS
$BODY$
/*
==============================================================================
  SCALAR - payroll
==============================================================================
*/
/*
--------------------------------------------------------------------------
  CPP base contribution: (pensionable earnings capped at the YMPE, less the
  basic exemption) at the year's contribution rate.

  This is the *annual* formula. Real per-period payroll prorates the basic
  exemption across pay periods; applying the annual formula to cumulative
  earnings (as payroll.usp_RunPayroll does) instead absorbs the whole
  exemption in the first period. The annual total for a full year of
  employment is identical either way, which is what matters for a fixture -
  but the period-by-period split differs from a CRA payroll calculation.
--------------------------------------------------------------------------
*/
DECLARE
    var_rate NUMERIC(9, 6);
    var_exemption NUMERIC(19, 2);
    var_ympe NUMERIC(19, 2);
    var_contributory NUMERIC(19, 2);
BEGIN
    IF par_PensionableEarnings IS NULL OR par_PensionableEarnings <= 0 THEN
        RETURN 0;
    END IF;
    SELECT
        p.cpprate, p.cppbasicexemption, p.ympe
        INTO var_rate, var_exemption, var_ympe
        FROM ref.payrollrate AS p
        WHERE p.taxyear = par_TaxYear;

    IF var_rate IS NULL THEN
        RETURN 0;
    END IF;
    /* no parameters loaded for the year */

    -- AWS SCT hoisted the T-SQL "DECLARE @x DECIMAL(19,2) = <expr>;" into a
    -- PL/pgSQL DECLARE ... DEFAULT. That changes when the expression runs:
    -- DECLARE defaults are evaluated on block entry, before the SELECT below
    -- has loaded the rate row, so the variable was computed from NULLs. In
    -- T-SQL the same statement sits *after* the SELECT. Assigning it here
    -- restores the original order of evaluation.
    var_contributory := (CASE
        WHEN par_PensionableEarnings > var_ympe THEN var_ympe
        ELSE par_PensionableEarnings
    END) - var_exemption;

    IF var_contributory <= 0 THEN
        RETURN 0;
    END IF;
    RETURN CAST (ROUND(var_contributory * var_rate, 2) AS NUMERIC(19, 2));
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION tax.fn_eipremium(IN par_taxyear INTEGER, IN par_insurableearnings NUMERIC, IN par_provincecode CHAR)
RETURNS NUMERIC
AS
$BODY$
/*
--------------------------------------------------------------------------
  EI premium. Quebec has its own (lower) rate because QPIP covers parental
  benefits separately.
--------------------------------------------------------------------------
*/
DECLARE
    var_rate NUMERIC(9, 6);
    var_mie NUMERIC(19, 2);
    var_insurable NUMERIC(19, 2);
BEGIN
    IF par_InsurableEarnings IS NULL OR par_InsurableEarnings <= 0 THEN
        RETURN 0;
    END IF;
    SELECT
        CASE
            WHEN LOWER(par_ProvinceCode) = LOWER('QC') THEN p.eiratequebec
            ELSE p.eirate
        END, p.eimaxinsurableearnings
        INTO var_rate, var_mie
        FROM ref.payrollrate AS p
        WHERE p.taxyear = par_TaxYear;

    IF var_rate IS NULL THEN
        RETURN 0;
    END IF;

    -- Same DECLARE ... DEFAULT ordering defect as in the CPP functions: the
    -- cap has to be applied after the MIE has been read, not on block entry.
    var_insurable :=
    CASE
        WHEN par_InsurableEarnings > var_mie THEN var_mie
        ELSE par_InsurableEarnings
    END;
    RETURN CAST (ROUND(var_insurable * var_rate, 2) AS NUMERIC(19, 2));
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION tax.fn_federaltax(IN par_taxyear INTEGER, IN par_taxableincome NUMERIC)
RETURNS NUMERIC
AS
$BODY$
BEGIN
    RETURN tax.fn_brackettax('CA', par_TaxYear, par_TaxableIncome);
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION tax.fn_isvalidbusinessnumber(IN par_businessnumber VARCHAR)
RETURNS NUMERIC
AS
$BODY$
/*
--------------------------------------------------------------------------
  Business Number. Accepts either the bare nine-digit registrant number or the
  full fifteen-character account form, e.g. 123456789RT0001.
--------------------------------------------------------------------------
*/
DECLARE
    var_bn VARCHAR(15) DEFAULT regexp_replace(par_BusinessNumber, ' ', '', 'gi');
BEGIN
    IF par_BusinessNumber IS NULL THEN
        RETURN 0;
    END IF;

    IF LENGTH(var_bn) = 15 THEN
        /* Program identifier: RT = GST/HST, RP = payroll, RC = corporate tax, */
        /* RM = import/export. Followed by a four-digit account reference. */
        IF LOWER(SUBSTR(var_bn, 10, 2)) NOT IN (LOWER('RT'), LOWER('RP'), LOWER('RC'), LOWER('RM')) THEN
            RETURN 0;
        END IF;

        IF LOWER(SUBSTR(var_bn, 12, 4)) NOT SIMILAR TO LOWER('[0-9][0-9][0-9][0-9]') THEN
            RETURN 0;
        END IF;
        var_bn := LEFT(var_bn, 9);
    END IF;

    IF LOWER(var_bn) NOT SIMILAR TO LOWER('[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]') THEN
        RETURN 0;
    END IF;
    RETURN util.fn_passesluhn(var_bn);
END;
$BODY$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION tax.fn_isvalidsin(IN par_sin CHAR)
RETURNS NUMERIC
AS
$BODY$
/*
--------------------------------------------------------------------------
  Social Insurance Number: nine digits with a Luhn check digit.
--------------------------------------------------------------------------
*/
BEGIN
    IF par_SIN IS NULL OR LOWER(par_SIN) NOT SIMILAR TO LOWER('[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]') THEN
        RETURN 0;
    END IF;
    -- AWS SCT generated util.fn_PassesLuhn(par_SIN::NUMERIC(18, 0)) here. That
    -- is wrong twice over: fn_PassesLuhn takes a VARCHAR, so the call does not
    -- even resolve; and casting to numeric would strip the leading zero from a
    -- SIN like 046454286, changing its length and breaking the check digit.
    -- The value is a digit string and is passed as one.
    RETURN util.fn_passesluhn(par_SIN::VARCHAR);
END;
$BODY$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION tax.fn_marginalrate(IN par_provincecode CHAR, IN par_taxyear INTEGER, IN par_taxableincome NUMERIC)
RETURNS NUMERIC
AS
$BODY$
/*
--------------------------------------------------------------------------
  Combined federal + provincial marginal rate: the rate that would apply to
  one more dollar of taxable income.
--------------------------------------------------------------------------
*/
DECLARE
    var_income NUMERIC(19, 2) DEFAULT
    CASE
        WHEN par_TaxableIncome < 0 OR par_TaxableIncome IS NULL THEN 0
        ELSE par_TaxableIncome
    END;
    var_federal NUMERIC(9, 6);
    var_provincial NUMERIC(9, 6);
BEGIN
    SELECT
        b.rate
        INTO var_federal
        FROM ref.taxbracket AS b
        WHERE b.taxyear = par_TaxYear AND LOWER(b.jurisdictioncode) = LOWER('CA') AND var_income >= b.lowerbound AND (b.upperbound IS NULL OR var_income < b.upperbound);
    SELECT
        b.rate
        INTO var_provincial
        FROM ref.taxbracket AS b
        WHERE b.taxyear = par_TaxYear AND LOWER(b.jurisdictioncode) = LOWER(par_ProvinceCode) AND var_income >= b.lowerbound AND (b.upperbound IS NULL OR var_income < b.upperbound);
    RETURN COALESCE(var_federal, 0) + COALESCE(var_provincial, 0);
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION tax.fn_provincialtax(IN par_provincecode CHAR, IN par_taxyear INTEGER, IN par_taxableincome NUMERIC)
RETURNS NUMERIC
AS
$BODY$
BEGIN
    RETURN tax.fn_brackettax(par_ProvinceCode, par_TaxYear, par_TaxableIncome);
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION tax.fn_taxbracketbreakdown(IN par_jurisdictioncode CHAR, IN par_taxyear INTEGER, IN par_taxableincome NUMERIC)
RETURNS TABLE (ordinal SMALLINT, lowerbound NUMERIC, upperbound NUMERIC, rate NUMERIC, incomeinbracket NUMERIC, taxinbracket NUMERIC, cumulativetax NUMERIC)
AS
$BODY$
/*
==============================================================================
  INLINE TABLE-VALUED FUNCTIONS
==============================================================================
*/
/*
--------------------------------------------------------------------------
  One row per bracket showing how much income fell in it and the tax that
  produced. Summing TaxInBracket must equal tax.fn_BracketTax for the same
  arguments - 099_verify.sql asserts exactly that.
--------------------------------------------------------------------------
*/
# variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT
        b.ordinal, b.lowerbound, b.upperbound, b.rate, CAST ((CASE
            WHEN b.upperbound IS NOT NULL AND par_TaxableIncome > b.upperbound THEN b.upperbound
            ELSE par_TaxableIncome
        END - b.lowerbound) AS NUMERIC(19, 2)) AS incomeinbracket, CAST (ROUND((CASE
            WHEN b.upperbound IS NOT NULL AND par_TaxableIncome > b.upperbound THEN b.upperbound
            ELSE par_TaxableIncome
        END - b.lowerbound) * b.rate, 2) AS NUMERIC(19, 2)) AS taxinbracket, SUM(CAST (ROUND((CASE
            WHEN b.upperbound IS NOT NULL AND par_TaxableIncome > b.upperbound THEN b.upperbound
            ELSE par_TaxableIncome
        END - b.lowerbound) * b.rate, 2) AS NUMERIC(19, 2))) OVER (ORDER BY b.ordinal ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulativetax
        FROM ref.taxbracket AS b
        WHERE LOWER(b.jurisdictioncode) = LOWER(par_JurisdictionCode) AND b.taxyear = par_TaxYear AND par_TaxableIncome > b.lowerbound;
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION util.fn_businessdaysbetween(IN par_fromdate DATE, IN par_todate DATE, IN par_jurisdictioncode CHAR)
RETURNS INTEGER
AS
$BODY$
/*
--------------------------------------------------------------------------
  Business days in [@FromDate, @ToDate), excluding weekends and statutory
  holidays for the given jurisdiction (national holidays always count).

  Weekend detection uses DATEDIFF from a known Monday rather than
  DATEPART(WEEKDAY, ...), which depends on the session's SET DATEFIRST and
  would therefore give different answers to different callers.
--------------------------------------------------------------------------
*/
DECLARE
    var_days INTEGER DEFAULT 0;
    var_cursor DATE DEFAULT par_FromDate;
    var_dow INTEGER;
BEGIN
    IF par_FromDate IS NULL OR par_ToDate IS NULL OR par_ToDate <= par_FromDate THEN
        RETURN 0;
    END IF;

    WHILE var_cursor < par_ToDate LOOP
        /* 1900-01-01 was a Monday, so 0 = Monday ... 5 = Saturday, 6 = Sunday. */
        var_dow := (((var_cursor)::date - ('19000101')::date) % 7)::INT;

        IF var_dow < 5 AND NOT EXISTS (SELECT
            1
            FROM ref.statutoryholiday AS h
            WHERE h.holidaydate = var_cursor AND LOWER(h.jurisdictioncode) IN (LOWER('CA'), LOWER(par_JurisdictionCode))) THEN
            var_days := (var_days + 1)::INT;
        END IF;
        var_cursor := var_cursor + (1::NUMERIC || ' DAY')::INTERVAL;
    END LOOP;
    RETURN var_days;
END;
$BODY$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION util.fn_passesluhn(IN par_digits VARCHAR)
RETURNS NUMERIC
AS
$BODY$
/*
==============================================================================
  SCALAR - identifier validation
==============================================================================
*/
/*
--------------------------------------------------------------------------
  Luhn (mod-10) check, digits doubled from the right. Shared by the SIN and
  Business Number validators, which differ only in their format rules.
--------------------------------------------------------------------------
*/
DECLARE
    var_sum INTEGER DEFAULT 0;
    var_pos INTEGER DEFAULT LENGTH(par_Digits);
    var_fromRight INTEGER DEFAULT 1;
    var_digit INTEGER;
BEGIN
    IF par_Digits IS NULL OR LENGTH(par_Digits) < 2 THEN
        RETURN 0;
    END IF;

    WHILE var_pos >= 1 LOOP
        var_digit := (ASCII(CASE SUBSTR(par_Digits, var_pos, 1)
            WHEN '' THEN NULL
            ELSE SUBSTR(par_Digits, var_pos, 1)
        END) - 48)::INT;

        IF var_digit < 0 OR var_digit > 9 THEN
            RETURN 0;
        END IF;
        /* non-numeric character */
        /* Every second digit counting from the right is doubled. */

        IF var_fromRight % 2 = 0 THEN
            var_digit := (var_digit * 2)::INT;

            IF var_digit > 9 THEN
                var_digit := (var_digit - 9)::INT;
            END IF;
        END IF;
        var_sum := var_sum + var_digit;
        var_pos := (var_pos - 1)::INT;
        var_fromRight := (var_fromRight + 1)::INT;
    END LOOP;
    RETURN
    CASE
        WHEN var_sum % 10 = 0 THEN 1
        ELSE 0
    END;
END;
$BODY$
LANGUAGE plpgsql IMMUTABLE;
