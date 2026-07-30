/*==============================================================================
  005 - Double-entry bookkeeping  [acct]

  PostgreSQL port of db/sqlserver/005_accounting_tables.sql.
  Bootstrapped from the AWS SCT output in db/postgres/generated/, then corrected
  by hand. See db/README.md for what SCT got wrong and why.
==============================================================================*/

CREATE TABLE IF NOT EXISTS acct.account(
    accountid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientid INTEGER NOT NULL,
    accountnumber VARCHAR(20) NOT NULL,
    accountname VARCHAR(100) NOT NULL,
    accounttypecode VARCHAR(20) NOT NULL,
    parentaccountid INTEGER,
    isactive NUMERIC(1,0) NOT NULL DEFAULT (1),
    iscontrolaccount NUMERIC(1,0) NOT NULL DEFAULT (0)
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS acct.fiscalyear(
    fiscalyearid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientid INTEGER NOT NULL,
    startdate DATE NOT NULL,
    enddate DATE NOT NULL,
    isclosed NUMERIC(1,0) NOT NULL DEFAULT (0),
    closedat TIMESTAMP(3) WITHOUT TIME ZONE
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS acct.invoice(
    invoiceid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    invoicenumber INTEGER NOT NULL,
    clientid INTEGER NOT NULL,
    engagementid INTEGER,
    invoicedate DATE NOT NULL,
    duedate DATE NOT NULL,
    provincecode CHAR(2) NOT NULL,
    subtotal NUMERIC(19,2) NOT NULL DEFAULT (0),
    gsthstamount NUMERIC(19,2) NOT NULL DEFAULT (0),
    pstamount NUMERIC(19,2) NOT NULL DEFAULT (0),
    total NUMERIC(21,2) NOT NULL GENERATED ALWAYS AS ((subtotal + gsthstamount) + pstamount) STORED,
    status VARCHAR(20) NOT NULL DEFAULT 'Draft',
    notes VARCHAR(400),
    createdat TIMESTAMP(3) WITHOUT TIME ZONE NOT NULL DEFAULT timezone('UTC', LOCALTIMESTAMP(6))
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS acct.invoiceline(
    invoicelineid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    invoiceid INTEGER NOT NULL,
    linenumber INTEGER NOT NULL,
    description VARCHAR(200) NOT NULL,
    quantity NUMERIC(9,2) NOT NULL DEFAULT (1),
    unitprice NUMERIC(19,2) NOT NULL,
    istaxable NUMERIC(1,0) NOT NULL DEFAULT (1),
    linetotal NUMERIC(19,2) NOT NULL GENERATED ALWAYS AS (round(quantity * unitprice, 2)::numeric(19,2)) STORED
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS acct.journalentry(
    journalentryid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientid INTEGER NOT NULL,
    fiscalyearid INTEGER NOT NULL,
    entrynumber INTEGER NOT NULL,
    entrydate DATE NOT NULL,
    description VARCHAR(300) NOT NULL,
    source VARCHAR(20) NOT NULL DEFAULT 'Manual',
    isposted NUMERIC(1,0) NOT NULL DEFAULT (0),
    postedat TIMESTAMP(3) WITHOUT TIME ZONE,
    postedby VARCHAR(128),
    reversedbyentryid INTEGER,
    createdat TIMESTAMP(3) WITHOUT TIME ZONE NOT NULL DEFAULT timezone('UTC', LOCALTIMESTAMP(6))
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS acct.journalline(
    journallineid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    journalentryid INTEGER NOT NULL,
    linenumber INTEGER NOT NULL,
    accountid INTEGER NOT NULL,
    debitamount NUMERIC(19,2) NOT NULL DEFAULT (0),
    creditamount NUMERIC(19,2) NOT NULL DEFAULT (0),
    memo VARCHAR(200)
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS acct.payment(
    paymentid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    invoiceid INTEGER NOT NULL,
    paymentdate DATE NOT NULL,
    amount NUMERIC(19,2) NOT NULL,
    method VARCHAR(20) NOT NULL,
    reference VARCHAR(60)
)
        WITH (
        OIDS=FALSE
        );
