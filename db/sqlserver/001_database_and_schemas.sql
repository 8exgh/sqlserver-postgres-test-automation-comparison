/*==============================================================================
  001 - Database, schemas, sequence and user-defined table types
  Runs against [master]. Everything after this file runs against the app DB.

  Idempotency strategy for the whole migration set:
    - tables/indexes    : IF OBJECT_ID(...) IS NULL CREATE ...   (non-destructive)
    - programmability   : CREATE OR ALTER
    - seed data         : MERGE
  So a full apply can be run repeatedly with the same end state. To rebuild from
  nothing, use scripts/reset-sqlserver.sh.
==============================================================================*/

IF DB_ID('CdnTaxPractice') IS NULL
BEGIN
    CREATE DATABASE CdnTaxPractice;
END
GO

ALTER DATABASE CdnTaxPractice SET RECOVERY SIMPLE;
GO

/*------------------------------------------------------------------------------
  Database-level SET options.

  The indexed view in 009 imposes a session-option contract: any connection that
  performs DML on its base tables must have ARITHABORT ON and NUMERIC_ROUNDABORT
  OFF, or the INSERT/UPDATE is rejected outright. The ODBC and .NET drivers set
  most ANSI options for you but leave ARITHABORT OFF, so setting the default here
  means test harnesses do not each have to remember to.
------------------------------------------------------------------------------*/
ALTER DATABASE CdnTaxPractice SET ARITHABORT ON;
GO
ALTER DATABASE CdnTaxPractice SET NUMERIC_ROUNDABORT OFF;
GO
ALTER DATABASE CdnTaxPractice SET ANSI_NULLS ON;
GO
ALTER DATABASE CdnTaxPractice SET ANSI_PADDING ON;
GO
ALTER DATABASE CdnTaxPractice SET ANSI_WARNINGS ON;
GO
ALTER DATABASE CdnTaxPractice SET QUOTED_IDENTIFIER ON;
GO
ALTER DATABASE CdnTaxPractice SET CONCAT_NULL_YIELDS_NULL ON;
GO

USE CdnTaxPractice;
GO

/*------------------------------------------------------------------------------
  Schemas. Objects are grouped by business domain rather than by object type, so
  cross-schema foreign keys and SCHEMABINDING both get exercised.
------------------------------------------------------------------------------*/
IF SCHEMA_ID('ref')     IS NULL EXEC('CREATE SCHEMA ref     AUTHORIZATION dbo;');
GO
IF SCHEMA_ID('client')  IS NULL EXEC('CREATE SCHEMA client  AUTHORIZATION dbo;');
GO
IF SCHEMA_ID('tax')     IS NULL EXEC('CREATE SCHEMA tax     AUTHORIZATION dbo;');
GO
IF SCHEMA_ID('acct')    IS NULL EXEC('CREATE SCHEMA acct    AUTHORIZATION dbo;');
GO
IF SCHEMA_ID('payroll') IS NULL EXEC('CREATE SCHEMA payroll AUTHORIZATION dbo;');
GO
IF SCHEMA_ID('audit')   IS NULL EXEC('CREATE SCHEMA audit   AUTHORIZATION dbo;');
GO
IF SCHEMA_ID('util')    IS NULL EXEC('CREATE SCHEMA util    AUTHORIZATION dbo;');
GO

/*------------------------------------------------------------------------------
  Sequence for human-facing invoice numbers. Deliberately a SEQUENCE rather than
  IDENTITY: invoice numbers are allocated by acct.usp_GenerateInvoice before the
  row is inserted, and the gapless-ness of IDENTITY is not required.
------------------------------------------------------------------------------*/
IF OBJECT_ID('acct.seq_InvoiceNumber', 'SO') IS NULL
BEGIN
    CREATE SEQUENCE acct.seq_InvoiceNumber
        AS INT
        START WITH 100000
        INCREMENT BY 1
        MINVALUE 100000
        NO CYCLE
        CACHE 20;
END
GO

/*------------------------------------------------------------------------------
  User-defined table types (used as table-valued parameters).

  Not dropped-and-recreated: a TYPE cannot be dropped while a procedure
  references it, so re-running this file must not attempt a DROP.
------------------------------------------------------------------------------*/
IF TYPE_ID('acct.JournalLineType') IS NULL
BEGIN
    CREATE TYPE acct.JournalLineType AS TABLE
    (
        LineNumber    INT            NOT NULL,
        AccountNumber NVARCHAR(20)   NOT NULL,
        DebitAmount   DECIMAL(19, 2) NOT NULL DEFAULT (0),
        CreditAmount  DECIMAL(19, 2) NOT NULL DEFAULT (0),
        Memo          NVARCHAR(200)  NULL,
        PRIMARY KEY CLUSTERED (LineNumber)
    );
END
GO

IF TYPE_ID('acct.InvoiceLineType') IS NULL
BEGIN
    CREATE TYPE acct.InvoiceLineType AS TABLE
    (
        LineNumber  INT            NOT NULL,
        Description NVARCHAR(200)  NOT NULL,
        Quantity    DECIMAL(9, 2)  NOT NULL DEFAULT (1),
        UnitPrice   DECIMAL(19, 2) NOT NULL,
        IsTaxable   BIT            NOT NULL DEFAULT (1),
        PRIMARY KEY CLUSTERED (LineNumber)
    );
END
GO

IF TYPE_ID('tax.SlipBoxType') IS NULL
BEGIN
    CREATE TYPE tax.SlipBoxType AS TABLE
    (
        BoxNumber NVARCHAR(10)   NOT NULL,
        Amount    DECIMAL(19, 2) NOT NULL,
        PRIMARY KEY CLUSTERED (BoxNumber)
    );
END
GO

PRINT '001 database, schemas, sequence and table types ready.';
GO
