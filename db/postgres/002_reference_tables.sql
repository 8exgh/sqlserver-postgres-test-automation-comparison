/*==============================================================================
  002 - Reference / lookup tables  [ref]

  PostgreSQL port of db/sqlserver/002_reference_tables.sql.
  Bootstrapped from the AWS SCT output in db/postgres/generated/, then corrected
  by hand. See db/README.md for what SCT got wrong and why.
==============================================================================*/

CREATE TABLE IF NOT EXISTS ref.accounttype(
    accounttypecode VARCHAR(20) NOT NULL,
    description VARCHAR(60) NOT NULL,
    normalbalance CHAR(1) NOT NULL,
    isnominal NUMERIC(1,0) NOT NULL,
    balancesheetorder SMALLINT NOT NULL
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS ref.filingfrequency(
    frequencycode VARCHAR(10) NOT NULL,
    description VARCHAR(40) NOT NULL,
    periodsperyear SMALLINT NOT NULL
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS ref.jurisdiction(
    jurisdictioncode CHAR(2) NOT NULL,
    jurisdictionname VARCHAR(60) NOT NULL,
    isfederal NUMERIC(1,0) NOT NULL DEFAULT (0),
    provincecode CHAR(2)
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS ref.nonrefundablecredit(
    creditcode VARCHAR(20) NOT NULL,
    taxyear SMALLINT NOT NULL,
    jurisdictioncode CHAR(2) NOT NULL,
    description VARCHAR(100) NOT NULL,
    maxamount NUMERIC(19,2) NOT NULL,
    creditrate NUMERIC(9,6) NOT NULL
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS ref.payrollrate(
    taxyear SMALLINT NOT NULL,
    cpprate NUMERIC(9,6) NOT NULL,
    cppbasicexemption NUMERIC(19,2) NOT NULL,
    ympe NUMERIC(19,2) NOT NULL,
    cpp2rate NUMERIC(9,6) NOT NULL DEFAULT (0),
    yampe NUMERIC(19,2) NOT NULL DEFAULT (0),
    eirate NUMERIC(9,6) NOT NULL,
    eiratequebec NUMERIC(9,6) NOT NULL,
    eimaxinsurableearnings NUMERIC(19,2) NOT NULL,
    employereimultiplier NUMERIC(9,4) NOT NULL DEFAULT (1.4)
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS ref.province(
    provincecode CHAR(2) NOT NULL,
    provincename VARCHAR(50) NOT NULL,
    isterritory NUMERIC(1,0) NOT NULL DEFAULT (0),
    sortorder SMALLINT NOT NULL
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS ref.salestaxrate(
    salestaxrateid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    provincecode CHAR(2) NOT NULL,
    effectivefrom DATE NOT NULL,
    effectiveto DATE,
    gstrate NUMERIC(9,5) NOT NULL DEFAULT (0),
    hstrate NUMERIC(9,5) NOT NULL DEFAULT (0),
    pstrate NUMERIC(9,5) NOT NULL DEFAULT (0),
    qstrate NUMERIC(9,5) NOT NULL DEFAULT (0),
    combinedrate NUMERIC(12,5) NOT NULL GENERATED ALWAYS AS (((gstrate + hstrate) + pstrate) + qstrate) STORED
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS ref.slipboxdefinition(
    sliptypecode VARCHAR(10) NOT NULL,
    boxnumber VARCHAR(10) NOT NULL,
    label VARCHAR(100) NOT NULL,
    incomecategory VARCHAR(30) NOT NULL
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS ref.sliptype(
    sliptypecode VARCHAR(10) NOT NULL,
    description VARCHAR(100) NOT NULL,
    issuedby VARCHAR(60) NOT NULL,
    isactive NUMERIC(1,0) NOT NULL DEFAULT (1)
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS ref.statutoryholiday(
    statutoryholidayid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    holidaydate DATE NOT NULL,
    holidayname VARCHAR(60) NOT NULL,
    jurisdictioncode CHAR(2) NOT NULL
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS ref.taxbracket(
    taxbracketid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    taxyear SMALLINT NOT NULL,
    jurisdictioncode CHAR(2) NOT NULL,
    ordinal SMALLINT NOT NULL,
    lowerbound NUMERIC(19,2) NOT NULL,
    upperbound NUMERIC(19,2),
    rate NUMERIC(9,6) NOT NULL
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS ref.taxyear(
    taxyear SMALLINT NOT NULL,
    t1filingdeadline DATE NOT NULL,
    selfemployeddeadline DATE NOT NULL,
    rrspdeadline DATE NOT NULL,
    installmentthreshold NUMERIC(19,2) NOT NULL DEFAULT (3000.00),
    islocked NUMERIC(1,0) NOT NULL DEFAULT (0)
)
        WITH (
        OIDS=FALSE
        );
