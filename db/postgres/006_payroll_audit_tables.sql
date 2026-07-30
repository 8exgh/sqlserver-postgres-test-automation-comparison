/*==============================================================================
  006 - Payroll and audit  [payroll] [audit]

  PostgreSQL port of db/sqlserver/006_payroll_audit_tables.sql.
  Bootstrapped from the AWS SCT output in db/postgres/generated/, then corrected
  by hand. See db/README.md for what SCT got wrong and why.
==============================================================================*/

CREATE TABLE IF NOT EXISTS payroll.employee(
    employeeid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    employerclientid INTEGER NOT NULL,
    employeenumber VARCHAR(20) NOT NULL,
    firstname VARCHAR(50) NOT NULL,
    lastname VARCHAR(50) NOT NULL,
    sin CHAR(9) NOT NULL,
    provinceofemployment CHAR(2) NOT NULL,
    hiredate DATE NOT NULL,
    terminationdate DATE,
    payfrequency VARCHAR(20) NOT NULL,
    annualsalary NUMERIC(19,2) NOT NULL,
    td1federalamount NUMERIC(19,2) NOT NULL DEFAULT (0),
    td1provincialamount NUMERIC(19,2) NOT NULL DEFAULT (0),
    isactive NUMERIC(1,0) NOT NULL DEFAULT (1)
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS payroll.payperiod(
    payperiodid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientid INTEGER NOT NULL,
    taxyear SMALLINT NOT NULL,
    periodnumber SMALLINT NOT NULL,
    startdate DATE NOT NULL,
    enddate DATE NOT NULL,
    paydate DATE NOT NULL,
    isprocessed NUMERIC(1,0) NOT NULL DEFAULT (0)
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS payroll.paystub(
    paystubid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    payperiodid INTEGER NOT NULL,
    employeeid INTEGER NOT NULL,
    grosspay NUMERIC(19,2) NOT NULL,
    cppdeducted NUMERIC(19,2) NOT NULL DEFAULT (0),
    cpp2deducted NUMERIC(19,2) NOT NULL DEFAULT (0),
    eideducted NUMERIC(19,2) NOT NULL DEFAULT (0),
    federaltaxdeducted NUMERIC(19,2) NOT NULL DEFAULT (0),
    provincialtaxdeducted NUMERIC(19,2) NOT NULL DEFAULT (0),
    otherdeductions NUMERIC(19,2) NOT NULL DEFAULT (0),
    netpay NUMERIC(25,2) NOT NULL GENERATED ALWAYS AS ((((((grosspay - cppdeducted) - cpp2deducted) - eideducted) - federaltaxdeducted) - provincialtaxdeducted) - otherdeductions) STORED
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS payroll.remittance(
    remittanceid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientid INTEGER NOT NULL,
    periodend DATE NOT NULL,
    duedate DATE NOT NULL,
    cppemployee NUMERIC(19,2) NOT NULL DEFAULT (0),
    cppemployer NUMERIC(19,2) NOT NULL DEFAULT (0),
    eiemployee NUMERIC(19,2) NOT NULL DEFAULT (0),
    eiemployer NUMERIC(19,2) NOT NULL DEFAULT (0),
    incometaxwithheld NUMERIC(19,2) NOT NULL DEFAULT (0),
    totalremittance NUMERIC(23,2) NOT NULL GENERATED ALWAYS AS ((((cppemployee + cppemployer) + eiemployee) + eiemployer) + incometaxwithheld) STORED,
    remitteddate DATE,
    confirmationnumber VARCHAR(40)
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS audit.changelog(
    changelogid BIGINT NOT NULL GENERATED ALWAYS AS IDENTITY,
    schemaname VARCHAR(128) NOT NULL,
    tablename VARCHAR(128) NOT NULL,
    primarykeyvalue VARCHAR(100) NOT NULL,
    operation CHAR(1) NOT NULL,
    changedby VARCHAR(128) NOT NULL DEFAULT CURRENT_USER,
    changedat TIMESTAMP(3) WITHOUT TIME ZONE NOT NULL DEFAULT timezone('UTC', LOCALTIMESTAMP(6)),
    -- SQL Server stores these as NVARCHAR(MAX) guarded by
    -- CK_ChangeLog_OldJson / CK_ChangeLog_NewJson (ISJSON(x) = 1). SCT drops
    -- both constraints because it cannot convert ISJSON (action item 7939),
    -- which would leave the column completely unguarded.
    --
    -- Typing the columns jsonb is the stronger PostgreSQL equivalent: invalid
    -- JSON is rejected by the type itself, so the CHECK is not merely ported
    -- but made redundant. It also lets audit.vw_RecentChanges shred the
    -- payload without a cast.
    oldvalues JSONB,
    newvalues JSONB
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS audit.returnstatushistory(
    returnstatushistoryid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    t1returnid INTEGER NOT NULL,
    oldstatus VARCHAR(20) NOT NULL,
    newstatus VARCHAR(20) NOT NULL,
    changedat TIMESTAMP(3) WITHOUT TIME ZONE NOT NULL DEFAULT timezone('UTC', LOCALTIMESTAMP(6)),
    changedby VARCHAR(128) NOT NULL DEFAULT CURRENT_USER
)
        WITH (
        OIDS=FALSE
        );
