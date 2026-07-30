/*==============================================================================
  003 - The practice and its clients  [client]

  PostgreSQL port of db/sqlserver/003_client_tables.sql.
  Bootstrapped from the AWS SCT output in db/postgres/generated/, then corrected
  by hand. See db/README.md for what SCT got wrong and why.
==============================================================================*/

CREATE TABLE IF NOT EXISTS client.client(
    clientid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientcode VARCHAR(20) NOT NULL,
    clienttype CHAR(1) NOT NULL,
    firstname VARCHAR(50),
    lastname VARCHAR(50),
    dateofbirth DATE,
    sin CHAR(9),
    maritalstatus VARCHAR(20),
    legalname VARCHAR(150),
    incorporationdate DATE,
    businessnumber CHAR(9),
    fiscalyearendmonth SMALLINT,
    provincecode CHAR(2) NOT NULL,
    onboardeddate DATE NOT NULL,
    isactive NUMERIC(1,0) NOT NULL DEFAULT (1),
    -- Two deviations from what AWS SCT generated, both forced by PostgreSQL's
    -- rules for generated columns:
    --   * SCT wrote LOWER(clienttype) = LOWER('C') to emulate SQL Server's
    --     case-insensitive collation. A generated column needs a resolvable
    --     collation, and LOWER() over a CHAR column has none, so this failed
    --     with "could not determine which collation to use for lower()" and
    --     took the whole table (and 74 dependent foreign keys) with it.
    --     CK_Client_Type already restricts the value to 'I' or 'C'.
    --   * CONCAT() is STABLE, not IMMUTABLE, so it is rejected outright.
    --     The || operator on text is immutable and equivalent here because
    --     COALESCE has already removed the NULLs that || would propagate.
    displayname VARCHAR(150) NOT NULL GENERATED ALWAYS AS (CASE
    WHEN clienttype = 'C' THEN COALESCE(legalname, '')
    ELSE COALESCE(lastname, '') || ', ' || COALESCE(firstname, '')
END) STORED,
    createdat TIMESTAMP(3) WITHOUT TIME ZONE NOT NULL DEFAULT timezone('UTC', LOCALTIMESTAMP(6)),
    updatedat TIMESTAMP(3) WITHOUT TIME ZONE,
    rowversion BIGINT NOT NULL
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS client.clientaddress(
    addressid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientid INTEGER NOT NULL,
    addresstype VARCHAR(20) NOT NULL DEFAULT 'Mailing',
    line1 VARCHAR(150) NOT NULL,
    line2 VARCHAR(150),
    city VARCHAR(80) NOT NULL,
    provincecode CHAR(2) NOT NULL,
    postalcode CHAR(7) NOT NULL,
    isprimary NUMERIC(1,0) NOT NULL DEFAULT (0)
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS client.clientcontact(
    contactid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientid INTEGER NOT NULL,
    contacttype VARCHAR(10) NOT NULL,
    contactvalue VARCHAR(150) NOT NULL,
    isprimary NUMERIC(1,0) NOT NULL DEFAULT (0)
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS client.engagement(
    engagementid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientid INTEGER NOT NULL,
    taxyear SMALLINT NOT NULL,
    servicetype VARCHAR(30) NOT NULL,
    practitionerid INTEGER NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'Open',
    feequoted NUMERIC(19,2) NOT NULL DEFAULT (0),
    feebilled NUMERIC(19,2),
    startedon DATE NOT NULL,
    completedon DATE
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS client.practitioner(
    practitionerid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    fullname VARCHAR(100) NOT NULL,
    designation VARCHAR(20),
    email VARCHAR(150) NOT NULL,
    ispartner NUMERIC(1,0) NOT NULL DEFAULT (0),
    isactive NUMERIC(1,0) NOT NULL DEFAULT (1)
)
        WITH (
        OIDS=FALSE
        );
