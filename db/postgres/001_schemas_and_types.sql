/*==============================================================================
  001 - Schemas, sequence and composite types

  PostgreSQL port of db/sqlserver/001_database_and_schemas.sql.
  Bootstrapped from the AWS SCT output in db/postgres/generated/, then corrected
  by hand. See db/README.md for what SCT got wrong and why.
==============================================================================*/

CREATE SCHEMA IF NOT EXISTS ref;
CREATE SCHEMA IF NOT EXISTS client;
CREATE SCHEMA IF NOT EXISTS tax;
CREATE SCHEMA IF NOT EXISTS acct;
CREATE SCHEMA IF NOT EXISTS payroll;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS util;

CREATE SEQUENCE IF NOT EXISTS acct.seq_invoicenumber AS bigint
INCREMENT BY 1
START WITH 100000
MAXVALUE 2147483647
MINVALUE 100000
NO CYCLE
CACHE 20;

/*------------------------------------------------------------------------------
  Composite types standing in for SQL Server's table-valued parameters.

  SCT emits a composite plus a DOMAIN over an array of it plus a helper function
  that materialises a temp table. A plain composite passed as an array is the
  idiomatic PostgreSQL equivalent and is what the procedures here take, so the
  domain and helper are dropped.

  NOT NULL is not carried over: PostgreSQL does not honour it inside a composite
  type (SCT action item 7689). The procedures validate instead.
------------------------------------------------------------------------------*/

-- CREATE TYPE has no IF NOT EXISTS, so the guard is explicit.
DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type t
                     JOIN pg_namespace n ON n.oid = t.typnamespace
                    WHERE t.typname = 'invoicelinetype' AND n.nspname = 'acct') THEN
        CREATE TYPE acct.invoicelinetype AS (
        linenumber INTEGER,
        description VARCHAR(200),
        quantity NUMERIC(9,2),
        unitprice NUMERIC(19,2),
        istaxable NUMERIC(1,0)
        );
    END IF;
END $do$;

-- CREATE TYPE has no IF NOT EXISTS, so the guard is explicit.
DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type t
                     JOIN pg_namespace n ON n.oid = t.typnamespace
                    WHERE t.typname = 'journallinetype' AND n.nspname = 'acct') THEN
        CREATE TYPE acct.journallinetype AS (
        linenumber INTEGER,
        accountnumber VARCHAR(20),
        debitamount NUMERIC(19,2),
        creditamount NUMERIC(19,2),
        memo VARCHAR(200)
        );
    END IF;
END $do$;

-- CREATE TYPE has no IF NOT EXISTS, so the guard is explicit.
DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type t
                     JOIN pg_namespace n ON n.oid = t.typnamespace
                    WHERE t.typname = 'slipboxtype' AND n.nspname = 'tax') THEN
        CREATE TYPE tax.slipboxtype AS (
        boxnumber VARCHAR(10),
        amount NUMERIC(19,2)
        );
    END IF;
END $do$;

/*------------------------------------------------------------------------------
  Backs the ROWVERSION emulation on client.Client.

  SQL Server's ROWVERSION column type is maintained by the engine. PostgreSQL
  has no equivalent, so client.tr_Client_BIU (011) takes the value from here and
  rejects any attempt to set it by hand. AWS SCT put this sequence in its own
  extension-pack schema; keeping it beside the table it serves means the port
  has no dependency on that schema at all.
------------------------------------------------------------------------------*/
CREATE SEQUENCE IF NOT EXISTS client.seq_rowversion AS bigint
    INCREMENT BY 1
    START WITH 1
    NO CYCLE;
