/*==============================================================================
  007 - Indexes, constraints and foreign keys

  PostgreSQL port of db/sqlserver/007_indexes_and_constraints.sql.
  Bootstrapped from the AWS SCT output in db/postgres/generated/, then corrected
  by hand. See db/README.md for what SCT got wrong and why.
==============================================================================*/

/*------------------------------------------------------------------------------
  Each constraint is added only if it is not already present. ALTER TABLE ...
  ADD CONSTRAINT has no IF NOT EXISTS, and dropping first is not an option
  either: a primary key that other constraints depend on cannot be dropped
  without CASCADE. Checking pg_constraint keeps the file re-runnable, which is
  what the SQL Server side does too.
------------------------------------------------------------------------------*/

/*---------------------------- Indexes ----------------------------*/
CREATE INDEX IF NOT EXISTS ix_account_clienttype
ON acct.account
USING BTREE (clientid ASC, accounttypecode ASC) INCLUDE(accountnumber, accountname, iscontrolaccount);

CREATE INDEX IF NOT EXISTS ix_account_parent
ON acct.account
USING BTREE (parentaccountid ASC) INCLUDE(clientid, accountnumber, accountname);

CREATE INDEX IF NOT EXISTS ix_invoice_clientdate
ON acct.invoice
USING BTREE (clientid ASC, invoicedate ASC) INCLUDE(duedate, subtotal, gsthstamount, pstamount, total, status);

CREATE INDEX IF NOT EXISTS ix_invoice_outstanding
ON acct.invoice
USING BTREE (duedate ASC, clientid ASC) INCLUDE(invoicenumber, total)
WHERE 
(LOWER(status) = LOWER('Sent'));

CREATE INDEX IF NOT EXISTS ix_journalentry_clientdate
ON acct.journalentry
USING BTREE (clientid ASC, entrydate ASC) INCLUDE(fiscalyearid, isposted, source, entrynumber);

CREATE INDEX IF NOT EXISTS ix_journalentry_unposted
ON acct.journalentry
USING BTREE (clientid ASC, entrydate ASC) INCLUDE(description)
WHERE 
(isposted = (0));

CREATE INDEX IF NOT EXISTS ix_journalline_account
ON acct.journalline
USING BTREE (accountid ASC) INCLUDE(journalentryid, debitamount, creditamount);

CREATE INDEX IF NOT EXISTS ix_payment_invoice
ON acct.payment
USING BTREE (invoiceid ASC, paymentdate ASC) INCLUDE(amount, method);

CREATE INDEX IF NOT EXISTS ix_changelog_changedat
ON audit.changelog
USING BTREE (changedat DESC) INCLUDE(schemaname, tablename, operation, changedby);

CREATE INDEX IF NOT EXISTS ix_changelog_row
ON audit.changelog
USING BTREE (tablename ASC, primarykeyvalue ASC, changedat DESC);

CREATE INDEX IF NOT EXISTS ix_returnstatushistory_return
ON audit.returnstatushistory
USING BTREE (t1returnid ASC, changedat DESC);

CREATE INDEX IF NOT EXISTS ix_client_active
ON client.client
USING BTREE (provincecode ASC, clienttype ASC) INCLUDE(clientcode, displayname)
WHERE 
(isactive = (1));

CREATE INDEX IF NOT EXISTS ix_client_displayname
ON client.client
USING BTREE (displayname ASC) INCLUDE(clientid, isactive);

CREATE UNIQUE INDEX IF NOT EXISTS ux_client_businessnumber
ON client.client
USING BTREE (businessnumber ASC)
WHERE 
(businessnumber IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS ux_client_sin
ON client.client
USING BTREE (sin ASC)
WHERE 
(sin IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS ux_clientaddress_primary
ON client.clientaddress
USING BTREE (clientid ASC)
WHERE 
(isprimary = (1));

CREATE UNIQUE INDEX IF NOT EXISTS ux_clientcontact_primary
ON client.clientcontact
USING BTREE (clientid ASC, contacttype ASC)
WHERE 
(isprimary = (1));

CREATE INDEX IF NOT EXISTS ix_engagement_practitioner
ON client.engagement
USING BTREE (practitionerid ASC, status ASC) INCLUDE(clientid, taxyear, feequoted);

CREATE INDEX IF NOT EXISTS ix_employee_employer
ON payroll.employee
USING BTREE (employerclientid ASC) INCLUDE(lastname, firstname, annualsalary)
WHERE 
(isactive = (1));

CREATE INDEX IF NOT EXISTS ix_payperiod_clientyear
ON payroll.payperiod
USING BTREE (clientid ASC, taxyear ASC, paydate ASC) INCLUDE(periodnumber, isprocessed);

CREATE INDEX IF NOT EXISTS ix_paystub_employee
ON payroll.paystub
USING BTREE (employeeid ASC) INCLUDE(payperiodid, grosspay, cppdeducted, cpp2deducted, eideducted, federaltaxdeducted, provincialtaxdeducted, netpay);

CREATE INDEX IF NOT EXISTS ix_salestaxrate_lookup
ON ref.salestaxrate
USING BTREE (provincecode ASC, effectivefrom ASC) INCLUDE(effectiveto, gstrate, hstrate, pstrate, qstrate, combinedrate);

CREATE INDEX IF NOT EXISTS ix_statutoryholiday_date
ON ref.statutoryholiday
USING BTREE (holidaydate ASC) INCLUDE(jurisdictioncode);

CREATE INDEX IF NOT EXISTS ix_taxbracket_lookup
ON ref.taxbracket
USING BTREE (taxyear ASC, jurisdictioncode ASC, ordinal ASC) INCLUDE(lowerbound, upperbound, rate);

CREATE INDEX IF NOT EXISTS ix_assessment_return
ON tax.assessment
USING BTREE (t1returnid ASC, assessedon DESC) INCLUDE(assessmenttype, totalpayable, balanceowing);

CREATE INDEX IF NOT EXISTS ix_gsthstreturn_unfiled
ON tax.gsthstreturn
USING BTREE (filingduedate ASC, clientid ASC) INCLUDE(periodstart, periodend)
WHERE 
(filedat IS NULL);

CREATE INDEX IF NOT EXISTS ix_installment_clientyear
ON tax.installment
USING BTREE (clientid ASC, taxyear ASC) INCLUDE(amountdue, amountpaid, duedate);

CREATE INDEX IF NOT EXISTS ix_slip_clientyear
ON tax.slip
USING BTREE (clientid ASC, taxyear ASC) INCLUDE(sliptypecode, issuername, isamended);

CREATE INDEX IF NOT EXISTS ix_slipbox_typebox
ON tax.slipbox
USING BTREE (sliptypecode ASC, boxnumber ASC) INCLUDE(slipid, amount);

CREATE INDEX IF NOT EXISTS ix_t1return_unfiled
ON tax.t1return
USING BTREE (taxyear ASC, clientid ASC) INCLUDE(filingstatus)
WHERE 
(datefiled IS NULL);

CREATE INDEX IF NOT EXISTS ix_t1return_yearstatus
ON tax.t1return
USING BTREE (taxyear ASC, filingstatus ASC) INCLUDE(clientid, taxableincome, totalpayable, balanceowing);


/*---------------------------- Primary keys, unique and check constraints ----------------------------*/
DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_account_notownparent'
                      AND conrelid = 'acct.account'::regclass) THEN
        ALTER TABLE acct.account ADD CONSTRAINT ck_account_notownparent CHECK (
        (parentaccountid IS NULL OR parentaccountid <> accountid));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_account'
                      AND conrelid = 'acct.account'::regclass) THEN
        ALTER TABLE acct.account ADD CONSTRAINT pk_account PRIMARY KEY (accountid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_account'
                      AND conrelid = 'acct.account'::regclass) THEN
        ALTER TABLE acct.account ADD CONSTRAINT uq_account UNIQUE (clientid, accountnumber);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_fiscalyear_closed'
                      AND conrelid = 'acct.fiscalyear'::regclass) THEN
        ALTER TABLE acct.fiscalyear ADD CONSTRAINT ck_fiscalyear_closed CHECK (
        (isclosed = (0) AND closedat IS NULL OR isclosed = (1) AND closedat IS NOT NULL));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_fiscalyear_period'
                      AND conrelid = 'acct.fiscalyear'::regclass) THEN
        ALTER TABLE acct.fiscalyear ADD CONSTRAINT ck_fiscalyear_period CHECK (
        (enddate > startdate));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_fiscalyear'
                      AND conrelid = 'acct.fiscalyear'::regclass) THEN
        ALTER TABLE acct.fiscalyear ADD CONSTRAINT pk_fiscalyear PRIMARY KEY (fiscalyearid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_fiscalyear'
                      AND conrelid = 'acct.fiscalyear'::regclass) THEN
        ALTER TABLE acct.fiscalyear ADD CONSTRAINT uq_fiscalyear UNIQUE (clientid, enddate);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_invoice_amounts'
                      AND conrelid = 'acct.invoice'::regclass) THEN
        ALTER TABLE acct.invoice ADD CONSTRAINT ck_invoice_amounts CHECK (
        (subtotal >= (0) AND gsthstamount >= (0) AND pstamount >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_invoice_dates'
                      AND conrelid = 'acct.invoice'::regclass) THEN
        ALTER TABLE acct.invoice ADD CONSTRAINT ck_invoice_dates CHECK (
        (duedate >= invoicedate));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_invoice_status'
                      AND conrelid = 'acct.invoice'::regclass) THEN
        ALTER TABLE acct.invoice ADD CONSTRAINT ck_invoice_status CHECK (
        (LOWER(status) = LOWER('WrittenOff') OR LOWER(status) = LOWER('Void') OR LOWER(status) = LOWER('Paid') OR LOWER(status) = LOWER('PartiallyPaid') OR LOWER(status) = LOWER('Sent') OR LOWER(status) = LOWER('Draft')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_invoice'
                      AND conrelid = 'acct.invoice'::regclass) THEN
        ALTER TABLE acct.invoice ADD CONSTRAINT pk_invoice PRIMARY KEY (invoiceid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_invoice_number'
                      AND conrelid = 'acct.invoice'::regclass) THEN
        ALTER TABLE acct.invoice ADD CONSTRAINT uq_invoice_number UNIQUE (invoicenumber);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_invoiceline_amounts'
                      AND conrelid = 'acct.invoiceline'::regclass) THEN
        ALTER TABLE acct.invoiceline ADD CONSTRAINT ck_invoiceline_amounts CHECK (
        (quantity > (0) AND unitprice >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_invoiceline'
                      AND conrelid = 'acct.invoiceline'::regclass) THEN
        ALTER TABLE acct.invoiceline ADD CONSTRAINT pk_invoiceline PRIMARY KEY (invoicelineid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_invoiceline'
                      AND conrelid = 'acct.invoiceline'::regclass) THEN
        ALTER TABLE acct.invoiceline ADD CONSTRAINT uq_invoiceline UNIQUE (invoiceid, linenumber);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_journalentry_noselfreversal'
                      AND conrelid = 'acct.journalentry'::regclass) THEN
        ALTER TABLE acct.journalentry ADD CONSTRAINT ck_journalentry_noselfreversal CHECK (
        (reversedbyentryid IS NULL OR reversedbyentryid <> journalentryid));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_journalentry_posted'
                      AND conrelid = 'acct.journalentry'::regclass) THEN
        ALTER TABLE acct.journalentry ADD CONSTRAINT ck_journalentry_posted CHECK (
        (isposted = (0) AND postedat IS NULL AND postedby IS NULL OR isposted = (1) AND postedat IS NOT NULL AND postedby IS NOT NULL));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_journalentry_source'
                      AND conrelid = 'acct.journalentry'::regclass) THEN
        ALTER TABLE acct.journalentry ADD CONSTRAINT ck_journalentry_source CHECK (
        (LOWER(source) = LOWER('Adjustment') OR LOWER(source) = LOWER('YearEnd') OR LOWER(source) = LOWER('Payroll') OR LOWER(source) = LOWER('Payment') OR LOWER(source) = LOWER('Invoice') OR LOWER(source) = LOWER('Manual')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_journalentry'
                      AND conrelid = 'acct.journalentry'::regclass) THEN
        ALTER TABLE acct.journalentry ADD CONSTRAINT pk_journalentry PRIMARY KEY (journalentryid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_journalentry'
                      AND conrelid = 'acct.journalentry'::regclass) THEN
        ALTER TABLE acct.journalentry ADD CONSTRAINT uq_journalentry UNIQUE (clientid, entrynumber);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_journalline_nonnegative'
                      AND conrelid = 'acct.journalline'::regclass) THEN
        ALTER TABLE acct.journalline ADD CONSTRAINT ck_journalline_nonnegative CHECK (
        (debitamount >= (0) AND creditamount >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_journalline_onesided'
                      AND conrelid = 'acct.journalline'::regclass) THEN
        ALTER TABLE acct.journalline ADD CONSTRAINT ck_journalline_onesided CHECK (
        (debitamount > (0) AND creditamount = (0) OR creditamount > (0) AND debitamount = (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_journalline'
                      AND conrelid = 'acct.journalline'::regclass) THEN
        ALTER TABLE acct.journalline ADD CONSTRAINT pk_journalline PRIMARY KEY (journallineid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_journalline'
                      AND conrelid = 'acct.journalline'::regclass) THEN
        ALTER TABLE acct.journalline ADD CONSTRAINT uq_journalline UNIQUE (journalentryid, linenumber);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_payment_amount'
                      AND conrelid = 'acct.payment'::regclass) THEN
        ALTER TABLE acct.payment ADD CONSTRAINT ck_payment_amount CHECK (
        (amount > (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_payment_method'
                      AND conrelid = 'acct.payment'::regclass) THEN
        ALTER TABLE acct.payment ADD CONSTRAINT ck_payment_method CHECK (
        (LOWER(method) = LOWER('Interac') OR LOWER(method) = LOWER('Cash') OR LOWER(method) = LOWER('CreditCard') OR LOWER(method) = LOWER('EFT') OR LOWER(method) = LOWER('Cheque')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_payment'
                      AND conrelid = 'acct.payment'::regclass) THEN
        ALTER TABLE acct.payment ADD CONSTRAINT pk_payment PRIMARY KEY (paymentid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_changelog_operation'
                      AND conrelid = 'audit.changelog'::regclass) THEN
        ALTER TABLE audit.changelog ADD CONSTRAINT ck_changelog_operation CHECK (
        (LOWER(operation) = LOWER('D') OR LOWER(operation) = LOWER('U') OR LOWER(operation) = LOWER('I')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_changelog_payload'
                      AND conrelid = 'audit.changelog'::regclass) THEN
        ALTER TABLE audit.changelog ADD CONSTRAINT ck_changelog_payload CHECK (
        (LOWER(operation) = LOWER('I') AND newvalues IS NOT NULL AND oldvalues IS NULL OR LOWER(operation) = LOWER('U') AND newvalues IS NOT NULL AND oldvalues IS NOT NULL OR LOWER(operation) = LOWER('D') AND newvalues IS NULL AND oldvalues IS NOT NULL));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_changelog'
                      AND conrelid = 'audit.changelog'::regclass) THEN
        ALTER TABLE audit.changelog ADD CONSTRAINT pk_changelog PRIMARY KEY (changelogid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_returnstatushistory_changed'
                      AND conrelid = 'audit.returnstatushistory'::regclass) THEN
        ALTER TABLE audit.returnstatushistory ADD CONSTRAINT ck_returnstatushistory_changed CHECK (
        (LOWER(oldstatus) <> LOWER(newstatus)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_returnstatushistory'
                      AND conrelid = 'audit.returnstatushistory'::regclass) THEN
        ALTER TABLE audit.returnstatushistory ADD CONSTRAINT pk_returnstatushistory PRIMARY KEY (returnstatushistoryid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_client_bndigits'
                      AND conrelid = 'client.client'::regclass) THEN
        ALTER TABLE client.client ADD CONSTRAINT ck_client_bndigits CHECK (
        (businessnumber IS NULL OR LOWER(businessnumber) SIMILAR TO LOWER('[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_client_fyemonth'
                      AND conrelid = 'client.client'::regclass) THEN
        ALTER TABLE client.client ADD CONSTRAINT ck_client_fyemonth CHECK (
        (fiscalyearendmonth IS NULL OR fiscalyearendmonth >= (1) AND fiscalyearendmonth <= (12)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_client_maritalstatus'
                      AND conrelid = 'client.client'::regclass) THEN
        ALTER TABLE client.client ADD CONSTRAINT ck_client_maritalstatus CHECK (
        (maritalstatus IS NULL OR (LOWER(maritalstatus) = LOWER('Widowed') OR LOWER(maritalstatus) = LOWER('Divorced') OR LOWER(maritalstatus) = LOWER('Separated') OR LOWER(maritalstatus) = LOWER('Common-law') OR LOWER(maritalstatus) = LOWER('Married') OR LOWER(maritalstatus) = LOWER('Single'))));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_client_sindigits'
                      AND conrelid = 'client.client'::regclass) THEN
        ALTER TABLE client.client ADD CONSTRAINT ck_client_sindigits CHECK (
        (sin IS NULL OR LOWER(sin) SIMILAR TO LOWER('[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_client_type'
                      AND conrelid = 'client.client'::regclass) THEN
        ALTER TABLE client.client ADD CONSTRAINT ck_client_type CHECK (
        (LOWER(clienttype) = LOWER('C') OR LOWER(clienttype) = LOWER('I')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_client_typeshape'
                      AND conrelid = 'client.client'::regclass) THEN
        ALTER TABLE client.client ADD CONSTRAINT ck_client_typeshape CHECK (
        (LOWER(clienttype) = LOWER('I') AND firstname IS NOT NULL AND lastname IS NOT NULL AND dateofbirth IS NOT NULL AND legalname IS NULL AND incorporationdate IS NULL AND businessnumber IS NULL AND fiscalyearendmonth IS NULL OR LOWER(clienttype) = LOWER('C') AND legalname IS NOT NULL AND incorporationdate IS NOT NULL AND fiscalyearendmonth IS NOT NULL AND firstname IS NULL AND lastname IS NULL AND dateofbirth IS NULL AND sin IS NULL AND maritalstatus IS NULL));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_client'
                      AND conrelid = 'client.client'::regclass) THEN
        ALTER TABLE client.client ADD CONSTRAINT pk_client PRIMARY KEY (clientid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_client_clientcode'
                      AND conrelid = 'client.client'::regclass) THEN
        ALTER TABLE client.client ADD CONSTRAINT uq_client_clientcode UNIQUE (clientcode);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_clientaddress_postalcode'
                      AND conrelid = 'client.clientaddress'::regclass) THEN
        ALTER TABLE client.clientaddress ADD CONSTRAINT ck_clientaddress_postalcode CHECK (
        (LOWER(postalcode) SIMILAR TO LOWER('[A-Z][0-9][A-Z] [0-9][A-Z][0-9]')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_clientaddress_type'
                      AND conrelid = 'client.clientaddress'::regclass) THEN
        ALTER TABLE client.clientaddress ADD CONSTRAINT ck_clientaddress_type CHECK (
        (LOWER(addresstype) = LOWER('RegisteredOffice') OR LOWER(addresstype) = LOWER('Physical') OR LOWER(addresstype) = LOWER('Mailing')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_clientaddress'
                      AND conrelid = 'client.clientaddress'::regclass) THEN
        ALTER TABLE client.clientaddress ADD CONSTRAINT pk_clientaddress PRIMARY KEY (addressid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_clientcontact_email'
                      AND conrelid = 'client.clientcontact'::regclass) THEN
        ALTER TABLE client.clientcontact ADD CONSTRAINT ck_clientcontact_email CHECK (
        (LOWER(contacttype) <> LOWER('Email') OR LOWER(contactvalue) LIKE LOWER('%_@_%._%')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_clientcontact_type'
                      AND conrelid = 'client.clientcontact'::regclass) THEN
        ALTER TABLE client.clientcontact ADD CONSTRAINT ck_clientcontact_type CHECK (
        (LOWER(contacttype) = LOWER('Fax') OR LOWER(contacttype) = LOWER('Mobile') OR LOWER(contacttype) = LOWER('Phone') OR LOWER(contacttype) = LOWER('Email')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_clientcontact'
                      AND conrelid = 'client.clientcontact'::regclass) THEN
        ALTER TABLE client.clientcontact ADD CONSTRAINT pk_clientcontact PRIMARY KEY (contactid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_engagement_dates'
                      AND conrelid = 'client.engagement'::regclass) THEN
        ALTER TABLE client.engagement ADD CONSTRAINT ck_engagement_dates CHECK (
        (completedon IS NULL OR completedon >= startedon));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_engagement_fees'
                      AND conrelid = 'client.engagement'::regclass) THEN
        ALTER TABLE client.engagement ADD CONSTRAINT ck_engagement_fees CHECK (
        (feequoted >= (0) AND (feebilled IS NULL OR feebilled >= (0))));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_engagement_service'
                      AND conrelid = 'client.engagement'::regclass) THEN
        ALTER TABLE client.engagement ADD CONSTRAINT ck_engagement_service CHECK (
        (LOWER(servicetype) = LOWER('Advisory') OR LOWER(servicetype) = LOWER('Review') OR LOWER(servicetype) = LOWER('Bookkeeping') OR LOWER(servicetype) = LOWER('Payroll') OR LOWER(servicetype) = LOWER('GSTHST') OR LOWER(servicetype) = LOWER('T2') OR LOWER(servicetype) = LOWER('T1')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_engagement_status'
                      AND conrelid = 'client.engagement'::regclass) THEN
        ALTER TABLE client.engagement ADD CONSTRAINT ck_engagement_status CHECK (
        (LOWER(status) = LOWER('Closed') OR LOWER(status) = LOWER('Filed') OR LOWER(status) = LOWER('AwaitingClient') OR LOWER(status) = LOWER('InProgress') OR LOWER(status) = LOWER('Open')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_engagement'
                      AND conrelid = 'client.engagement'::regclass) THEN
        ALTER TABLE client.engagement ADD CONSTRAINT pk_engagement PRIMARY KEY (engagementid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_engagement'
                      AND conrelid = 'client.engagement'::regclass) THEN
        ALTER TABLE client.engagement ADD CONSTRAINT uq_engagement UNIQUE (clientid, taxyear, servicetype);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_practitioner'
                      AND conrelid = 'client.practitioner'::regclass) THEN
        ALTER TABLE client.practitioner ADD CONSTRAINT pk_practitioner PRIMARY KEY (practitionerid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_practitioner_email'
                      AND conrelid = 'client.practitioner'::regclass) THEN
        ALTER TABLE client.practitioner ADD CONSTRAINT uq_practitioner_email UNIQUE (email);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_employee_payfrequency'
                      AND conrelid = 'payroll.employee'::regclass) THEN
        ALTER TABLE payroll.employee ADD CONSTRAINT ck_employee_payfrequency CHECK (
        (LOWER(payfrequency) = LOWER('Monthly') OR LOWER(payfrequency) = LOWER('SemiMonthly') OR LOWER(payfrequency) = LOWER('BiWeekly') OR LOWER(payfrequency) = LOWER('Weekly')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_employee_salary'
                      AND conrelid = 'payroll.employee'::regclass) THEN
        ALTER TABLE payroll.employee ADD CONSTRAINT ck_employee_salary CHECK (
        (annualsalary >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_employee_sin'
                      AND conrelid = 'payroll.employee'::regclass) THEN
        ALTER TABLE payroll.employee ADD CONSTRAINT ck_employee_sin CHECK (
        (LOWER(sin) SIMILAR TO LOWER('[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_employee_termination'
                      AND conrelid = 'payroll.employee'::regclass) THEN
        ALTER TABLE payroll.employee ADD CONSTRAINT ck_employee_termination CHECK (
        (terminationdate IS NULL OR terminationdate >= hiredate));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_employee'
                      AND conrelid = 'payroll.employee'::regclass) THEN
        ALTER TABLE payroll.employee ADD CONSTRAINT pk_employee PRIMARY KEY (employeeid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_employee'
                      AND conrelid = 'payroll.employee'::regclass) THEN
        ALTER TABLE payroll.employee ADD CONSTRAINT uq_employee UNIQUE (employerclientid, employeenumber);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_payperiod_number'
                      AND conrelid = 'payroll.payperiod'::regclass) THEN
        ALTER TABLE payroll.payperiod ADD CONSTRAINT ck_payperiod_number CHECK (
        (periodnumber >= (1) AND periodnumber <= (53)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_payperiod_paydate'
                      AND conrelid = 'payroll.payperiod'::regclass) THEN
        ALTER TABLE payroll.payperiod ADD CONSTRAINT ck_payperiod_paydate CHECK (
        (paydate >= enddate));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_payperiod_range'
                      AND conrelid = 'payroll.payperiod'::regclass) THEN
        ALTER TABLE payroll.payperiod ADD CONSTRAINT ck_payperiod_range CHECK (
        (enddate > startdate));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_payperiod'
                      AND conrelid = 'payroll.payperiod'::regclass) THEN
        ALTER TABLE payroll.payperiod ADD CONSTRAINT pk_payperiod PRIMARY KEY (payperiodid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_payperiod'
                      AND conrelid = 'payroll.payperiod'::regclass) THEN
        ALTER TABLE payroll.payperiod ADD CONSTRAINT uq_payperiod UNIQUE (clientid, taxyear, periodnumber);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_paystub_nonnegative'
                      AND conrelid = 'payroll.paystub'::regclass) THEN
        ALTER TABLE payroll.paystub ADD CONSTRAINT ck_paystub_nonnegative CHECK (
        (grosspay >= (0) AND cppdeducted >= (0) AND cpp2deducted >= (0) AND eideducted >= (0) AND federaltaxdeducted >= (0) AND provincialtaxdeducted >= (0) AND otherdeductions >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_paystub'
                      AND conrelid = 'payroll.paystub'::regclass) THEN
        ALTER TABLE payroll.paystub ADD CONSTRAINT pk_paystub PRIMARY KEY (paystubid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_paystub'
                      AND conrelid = 'payroll.paystub'::regclass) THEN
        ALTER TABLE payroll.paystub ADD CONSTRAINT uq_paystub UNIQUE (payperiodid, employeeid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_remittance_amounts'
                      AND conrelid = 'payroll.remittance'::regclass) THEN
        ALTER TABLE payroll.remittance ADD CONSTRAINT ck_remittance_amounts CHECK (
        (cppemployee >= (0) AND cppemployer >= (0) AND eiemployee >= (0) AND eiemployer >= (0) AND incometaxwithheld >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_remittance_due'
                      AND conrelid = 'payroll.remittance'::regclass) THEN
        ALTER TABLE payroll.remittance ADD CONSTRAINT ck_remittance_due CHECK (
        (duedate > periodend));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_remittance'
                      AND conrelid = 'payroll.remittance'::regclass) THEN
        ALTER TABLE payroll.remittance ADD CONSTRAINT pk_remittance PRIMARY KEY (remittanceid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_remittance'
                      AND conrelid = 'payroll.remittance'::regclass) THEN
        ALTER TABLE payroll.remittance ADD CONSTRAINT uq_remittance UNIQUE (clientid, periodend);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_accounttype_normalbalance'
                      AND conrelid = 'ref.accounttype'::regclass) THEN
        ALTER TABLE ref.accounttype ADD CONSTRAINT ck_accounttype_normalbalance CHECK (
        (LOWER(normalbalance) = LOWER('C') OR LOWER(normalbalance) = LOWER('D')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_accounttype'
                      AND conrelid = 'ref.accounttype'::regclass) THEN
        ALTER TABLE ref.accounttype ADD CONSTRAINT pk_accounttype PRIMARY KEY (accounttypecode);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_filingfrequency_periods'
                      AND conrelid = 'ref.filingfrequency'::regclass) THEN
        ALTER TABLE ref.filingfrequency ADD CONSTRAINT ck_filingfrequency_periods CHECK (
        (periodsperyear = (12) OR periodsperyear = (4) OR periodsperyear = (1)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_filingfrequency'
                      AND conrelid = 'ref.filingfrequency'::regclass) THEN
        ALTER TABLE ref.filingfrequency ADD CONSTRAINT pk_filingfrequency PRIMARY KEY (frequencycode);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_jurisdiction_province'
                      AND conrelid = 'ref.jurisdiction'::regclass) THEN
        ALTER TABLE ref.jurisdiction ADD CONSTRAINT ck_jurisdiction_province CHECK (
        (isfederal = (1) AND provincecode IS NULL OR isfederal = (0) AND provincecode IS NOT NULL));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_jurisdiction'
                      AND conrelid = 'ref.jurisdiction'::regclass) THEN
        ALTER TABLE ref.jurisdiction ADD CONSTRAINT pk_jurisdiction PRIMARY KEY (jurisdictioncode);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_nonrefundablecredit_amount'
                      AND conrelid = 'ref.nonrefundablecredit'::regclass) THEN
        ALTER TABLE ref.nonrefundablecredit ADD CONSTRAINT ck_nonrefundablecredit_amount CHECK (
        (maxamount >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_nonrefundablecredit'
                      AND conrelid = 'ref.nonrefundablecredit'::regclass) THEN
        ALTER TABLE ref.nonrefundablecredit ADD CONSTRAINT pk_nonrefundablecredit PRIMARY KEY (taxyear, jurisdictioncode, creditcode);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_payrollrate_rates'
                      AND conrelid = 'ref.payrollrate'::regclass) THEN
        ALTER TABLE ref.payrollrate ADD CONSTRAINT ck_payrollrate_rates CHECK (
        (cpprate >= (0) AND cpprate <= (1) AND (cpp2rate >= (0) AND cpp2rate <= (1)) AND (eirate >= (0) AND eirate <= (1)) AND (eiratequebec >= (0) AND eiratequebec <= (1))));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_payrollrate_yampe'
                      AND conrelid = 'ref.payrollrate'::regclass) THEN
        ALTER TABLE ref.payrollrate ADD CONSTRAINT ck_payrollrate_yampe CHECK (
        (yampe = (0) OR yampe >= ympe));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_payrollrate_ympe'
                      AND conrelid = 'ref.payrollrate'::regclass) THEN
        ALTER TABLE ref.payrollrate ADD CONSTRAINT ck_payrollrate_ympe CHECK (
        (ympe > cppbasicexemption));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_payrollrate'
                      AND conrelid = 'ref.payrollrate'::regclass) THEN
        ALTER TABLE ref.payrollrate ADD CONSTRAINT pk_payrollrate PRIMARY KEY (taxyear);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_province_code'
                      AND conrelid = 'ref.province'::regclass) THEN
        ALTER TABLE ref.province ADD CONSTRAINT ck_province_code CHECK (
        (LOWER(provincecode) = LOWER(UPPER(provincecode))));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_province'
                      AND conrelid = 'ref.province'::regclass) THEN
        ALTER TABLE ref.province ADD CONSTRAINT pk_province PRIMARY KEY (provincecode);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_province_name'
                      AND conrelid = 'ref.province'::regclass) THEN
        ALTER TABLE ref.province ADD CONSTRAINT uq_province_name UNIQUE (provincename);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_salestaxrate_hstxorgst'
                      AND conrelid = 'ref.salestaxrate'::regclass) THEN
        ALTER TABLE ref.salestaxrate ADD CONSTRAINT ck_salestaxrate_hstxorgst CHECK (
        (hstrate > (0) AND gstrate = (0) AND pstrate = (0) AND qstrate = (0) OR hstrate = (0) AND gstrate > (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_salestaxrate_nonnegative'
                      AND conrelid = 'ref.salestaxrate'::regclass) THEN
        ALTER TABLE ref.salestaxrate ADD CONSTRAINT ck_salestaxrate_nonnegative CHECK (
        (gstrate >= (0) AND hstrate >= (0) AND pstrate >= (0) AND qstrate >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_salestaxrate_range'
                      AND conrelid = 'ref.salestaxrate'::regclass) THEN
        ALTER TABLE ref.salestaxrate ADD CONSTRAINT ck_salestaxrate_range CHECK (
        (effectiveto IS NULL OR effectiveto > effectivefrom));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_salestaxrate'
                      AND conrelid = 'ref.salestaxrate'::regclass) THEN
        ALTER TABLE ref.salestaxrate ADD CONSTRAINT pk_salestaxrate PRIMARY KEY (salestaxrateid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_salestaxrate_province_from'
                      AND conrelid = 'ref.salestaxrate'::regclass) THEN
        ALTER TABLE ref.salestaxrate ADD CONSTRAINT uq_salestaxrate_province_from UNIQUE (provincecode, effectivefrom);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_slipboxdefinition_category'
                      AND conrelid = 'ref.slipboxdefinition'::regclass) THEN
        ALTER TABLE ref.slipboxdefinition ADD CONSTRAINT ck_slipboxdefinition_category CHECK (
        (LOWER(incomecategory) = LOWER('NonIncome') OR LOWER(incomecategory) = LOWER('EI') OR LOWER(incomecategory) = LOWER('CPP') OR LOWER(incomecategory) = LOWER('TaxWithheld') OR LOWER(incomecategory) = LOWER('Deduction') OR LOWER(incomecategory) = LOWER('Other') OR LOWER(incomecategory) = LOWER('Pension') OR LOWER(incomecategory) = LOWER('SelfEmployment') OR LOWER(incomecategory) = LOWER('Investment') OR LOWER(incomecategory) = LOWER('Employment')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_slipboxdefinition'
                      AND conrelid = 'ref.slipboxdefinition'::regclass) THEN
        ALTER TABLE ref.slipboxdefinition ADD CONSTRAINT pk_slipboxdefinition PRIMARY KEY (sliptypecode, boxnumber);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_sliptype'
                      AND conrelid = 'ref.sliptype'::regclass) THEN
        ALTER TABLE ref.sliptype ADD CONSTRAINT pk_sliptype PRIMARY KEY (sliptypecode);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_statutoryholiday'
                      AND conrelid = 'ref.statutoryholiday'::regclass) THEN
        ALTER TABLE ref.statutoryholiday ADD CONSTRAINT pk_statutoryholiday PRIMARY KEY (statutoryholidayid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_statutoryholiday'
                      AND conrelid = 'ref.statutoryholiday'::regclass) THEN
        ALTER TABLE ref.statutoryholiday ADD CONSTRAINT uq_statutoryholiday UNIQUE (holidaydate, jurisdictioncode);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_taxbracket_bounds'
                      AND conrelid = 'ref.taxbracket'::regclass) THEN
        ALTER TABLE ref.taxbracket ADD CONSTRAINT ck_taxbracket_bounds CHECK (
        (upperbound IS NULL OR upperbound > lowerbound));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_taxbracket_lower'
                      AND conrelid = 'ref.taxbracket'::regclass) THEN
        ALTER TABLE ref.taxbracket ADD CONSTRAINT ck_taxbracket_lower CHECK (
        (lowerbound >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_taxbracket_rate'
                      AND conrelid = 'ref.taxbracket'::regclass) THEN
        ALTER TABLE ref.taxbracket ADD CONSTRAINT ck_taxbracket_rate CHECK (
        (rate >= (0) AND rate <= (1)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_taxbracket'
                      AND conrelid = 'ref.taxbracket'::regclass) THEN
        ALTER TABLE ref.taxbracket ADD CONSTRAINT pk_taxbracket PRIMARY KEY (taxbracketid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_taxbracket'
                      AND conrelid = 'ref.taxbracket'::regclass) THEN
        ALTER TABLE ref.taxbracket ADD CONSTRAINT uq_taxbracket UNIQUE (taxyear, jurisdictioncode, ordinal);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_taxyear_deadlines'
                      AND conrelid = 'ref.taxyear'::regclass) THEN
        ALTER TABLE ref.taxyear ADD CONSTRAINT ck_taxyear_deadlines CHECK (
        (selfemployeddeadline >= t1filingdeadline));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_taxyear_range'
                      AND conrelid = 'ref.taxyear'::regclass) THEN
        ALTER TABLE ref.taxyear ADD CONSTRAINT ck_taxyear_range CHECK (
        (taxyear >= (1990) AND taxyear <= (2100)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_taxyear'
                      AND conrelid = 'ref.taxyear'::regclass) THEN
        ALTER TABLE ref.taxyear ADD CONSTRAINT pk_taxyear PRIMARY KEY (taxyear);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_assessment_type'
                      AND conrelid = 'tax.assessment'::regclass) THEN
        ALTER TABLE tax.assessment ADD CONSTRAINT ck_assessment_type CHECK (
        (LOWER(assessmenttype) = LOWER('Recalculation') OR LOWER(assessmenttype) = LOWER('Reassessment') OR LOWER(assessmenttype) = LOWER('Original')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_assessment'
                      AND conrelid = 'tax.assessment'::regclass) THEN
        ALTER TABLE tax.assessment ADD CONSTRAINT pk_assessment PRIMARY KEY (assessmentid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_creditclaim_amount'
                      AND conrelid = 'tax.creditclaim'::regclass) THEN
        ALTER TABLE tax.creditclaim ADD CONSTRAINT ck_creditclaim_amount CHECK (
        (claimedamount >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_creditclaim'
                      AND conrelid = 'tax.creditclaim'::regclass) THEN
        ALTER TABLE tax.creditclaim ADD CONSTRAINT pk_creditclaim PRIMARY KEY (creditclaimid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_creditclaim'
                      AND conrelid = 'tax.creditclaim'::regclass) THEN
        ALTER TABLE tax.creditclaim ADD CONSTRAINT uq_creditclaim UNIQUE (t1returnid, jurisdictioncode, creditcode);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_gsthstreturn_amounts'
                      AND conrelid = 'tax.gsthstreturn'::regclass) THEN
        ALTER TABLE tax.gsthstreturn ADD CONSTRAINT ck_gsthstreturn_amounts CHECK (
        (line101sales >= (0) AND line105taxcollected >= (0) AND line108inputtaxcredits >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_gsthstreturn_filed'
                      AND conrelid = 'tax.gsthstreturn'::regclass) THEN
        ALTER TABLE tax.gsthstreturn ADD CONSTRAINT ck_gsthstreturn_filed CHECK (
        (LOWER(status) = LOWER('Open') AND filedat IS NULL OR LOWER(status) <> LOWER('Open') AND filedat IS NOT NULL));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_gsthstreturn_period'
                      AND conrelid = 'tax.gsthstreturn'::regclass) THEN
        ALTER TABLE tax.gsthstreturn ADD CONSTRAINT ck_gsthstreturn_period CHECK (
        (periodend > periodstart));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_gsthstreturn_status'
                      AND conrelid = 'tax.gsthstreturn'::regclass) THEN
        ALTER TABLE tax.gsthstreturn ADD CONSTRAINT ck_gsthstreturn_status CHECK (
        (LOWER(status) = LOWER('Assessed') OR LOWER(status) = LOWER('Paid') OR LOWER(status) = LOWER('Filed') OR LOWER(status) = LOWER('Open')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_gsthstreturn'
                      AND conrelid = 'tax.gsthstreturn'::regclass) THEN
        ALTER TABLE tax.gsthstreturn ADD CONSTRAINT pk_gsthstreturn PRIMARY KEY (gsthstreturnid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_gsthstreturn'
                      AND conrelid = 'tax.gsthstreturn'::regclass) THEN
        ALTER TABLE tax.gsthstreturn ADD CONSTRAINT uq_gsthstreturn UNIQUE (clientid, periodstart);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_installment_amounts'
                      AND conrelid = 'tax.installment'::regclass) THEN
        ALTER TABLE tax.installment ADD CONSTRAINT ck_installment_amounts CHECK (
        (amountdue >= (0) AND amountpaid >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_installment_paiddate'
                      AND conrelid = 'tax.installment'::regclass) THEN
        ALTER TABLE tax.installment ADD CONSTRAINT ck_installment_paiddate CHECK (
        (amountpaid = (0) AND paiddate IS NULL OR amountpaid > (0) AND paiddate IS NOT NULL));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_installment'
                      AND conrelid = 'tax.installment'::regclass) THEN
        ALTER TABLE tax.installment ADD CONSTRAINT pk_installment PRIMARY KEY (installmentid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_installment'
                      AND conrelid = 'tax.installment'::regclass) THEN
        ALTER TABLE tax.installment ADD CONSTRAINT uq_installment UNIQUE (clientid, taxyear, duedate);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_rrsp_amount'
                      AND conrelid = 'tax.rrspcontribution'::regclass) THEN
        ALTER TABLE tax.rrspcontribution ADD CONSTRAINT ck_rrsp_amount CHECK (
        (amount > (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_rrspcontribution'
                      AND conrelid = 'tax.rrspcontribution'::regclass) THEN
        ALTER TABLE tax.rrspcontribution ADD CONSTRAINT pk_rrspcontribution PRIMARY KEY (rrspcontributionid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_slip_issuerbn'
                      AND conrelid = 'tax.slip'::regclass) THEN
        ALTER TABLE tax.slip ADD CONSTRAINT ck_slip_issuerbn CHECK (
        (issuerbusinessnumber IS NULL OR LOWER(issuerbusinessnumber) SIMILAR TO LOWER('[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_slip'
                      AND conrelid = 'tax.slip'::regclass) THEN
        ALTER TABLE tax.slip ADD CONSTRAINT pk_slip PRIMARY KEY (slipid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_slip'
                      AND conrelid = 'tax.slip'::regclass) THEN
        ALTER TABLE tax.slip ADD CONSTRAINT uq_slip UNIQUE (clientid, taxyear, sliptypecode, slipreference);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_slip_idtype'
                      AND conrelid = 'tax.slip'::regclass) THEN
        ALTER TABLE tax.slip ADD CONSTRAINT uq_slip_idtype UNIQUE (slipid, sliptypecode);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_slipbox'
                      AND conrelid = 'tax.slipbox'::regclass) THEN
        ALTER TABLE tax.slipbox ADD CONSTRAINT pk_slipbox PRIMARY KEY (slipid, boxnumber);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_t1return_deductions'
                      AND conrelid = 'tax.t1return'::regclass) THEN
        ALTER TABLE tax.t1return ADD CONSTRAINT ck_t1return_deductions CHECK (
        (rrspdeduction >= (0) AND uniondues >= (0) AND childcareexpenses >= (0) AND otherdeductions >= (0) AND losscarryforward >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_t1return_fileddate'
                      AND conrelid = 'tax.t1return'::regclass) THEN
        ALTER TABLE tax.t1return ADD CONSTRAINT ck_t1return_fileddate CHECK (
        ((LOWER(filingstatus) = LOWER('Ready') OR LOWER(filingstatus) = LOWER('Draft')) AND datefiled IS NULL OR (LOWER(filingstatus) = LOWER('Reassessed') OR LOWER(filingstatus) = LOWER('Assessed') OR LOWER(filingstatus) = LOWER('Filed')) AND datefiled IS NOT NULL));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_t1return_income'
                      AND conrelid = 'tax.t1return'::regclass) THEN
        ALTER TABLE tax.t1return ADD CONSTRAINT ck_t1return_income CHECK (
        (employmentincome >= (0) AND selfemploymentincome >= (0) AND pensionincome >= (0) AND otherincome >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_t1return_status'
                      AND conrelid = 'tax.t1return'::regclass) THEN
        ALTER TABLE tax.t1return ADD CONSTRAINT ck_t1return_status CHECK (
        (LOWER(filingstatus) = LOWER('Reassessed') OR LOWER(filingstatus) = LOWER('Assessed') OR LOWER(filingstatus) = LOWER('Filed') OR LOWER(filingstatus) = LOWER('Ready') OR LOWER(filingstatus) = LOWER('Draft')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_t1return'
                      AND conrelid = 'tax.t1return'::regclass) THEN
        ALTER TABLE tax.t1return ADD CONSTRAINT pk_t1return PRIMARY KEY (t1returnid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_t1return'
                      AND conrelid = 'tax.t1return'::regclass) THEN
        ALTER TABLE tax.t1return ADD CONSTRAINT uq_t1return UNIQUE (clientid, taxyear);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_t2return_amounts'
                      AND conrelid = 'tax.t2return'::regclass) THEN
        ALTER TABLE tax.t2return ADD CONSTRAINT ck_t2return_amounts CHECK (
        (grossrevenue >= (0) AND totalexpenses >= (0) AND smallbusinessdeduction >= (0)));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_t2return_period'
                      AND conrelid = 'tax.t2return'::regclass) THEN
        ALTER TABLE tax.t2return ADD CONSTRAINT ck_t2return_period CHECK (
        (fiscalyearend > fiscalyearstart));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_t2return_periodlength'
                      AND conrelid = 'tax.t2return'::regclass) THEN
        ALTER TABLE tax.t2return ADD CONSTRAINT ck_t2return_periodlength CHECK (
        ((fiscalyearend - fiscalyearstart) <= 371));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_t2return_status'
                      AND conrelid = 'tax.t2return'::regclass) THEN
        ALTER TABLE tax.t2return ADD CONSTRAINT ck_t2return_status CHECK (
        (LOWER(filingstatus) = LOWER('Reassessed') OR LOWER(filingstatus) = LOWER('Assessed') OR LOWER(filingstatus) = LOWER('Filed') OR LOWER(filingstatus) = LOWER('Ready') OR LOWER(filingstatus) = LOWER('Draft')));
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'pk_t2return'
                      AND conrelid = 'tax.t2return'::regclass) THEN
        ALTER TABLE tax.t2return ADD CONSTRAINT pk_t2return PRIMARY KEY (t2returnid);
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'uq_t2return'
                      AND conrelid = 'tax.t2return'::regclass) THEN
        ALTER TABLE tax.t2return ADD CONSTRAINT uq_t2return UNIQUE (clientid, fiscalyearend);
    END IF;
END $do$;


/*---------------------------- Foreign keys ----------------------------*/
DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_account_accounttype'
                      AND conrelid = 'acct.account'::regclass) THEN
        ALTER TABLE acct.account ADD CONSTRAINT fk_account_accounttype FOREIGN KEY (accounttypecode) 
        REFERENCES ref.accounttype (accounttypecode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_account_client'
                      AND conrelid = 'acct.account'::regclass) THEN
        ALTER TABLE acct.account ADD CONSTRAINT fk_account_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_account_parent'
                      AND conrelid = 'acct.account'::regclass) THEN
        ALTER TABLE acct.account ADD CONSTRAINT fk_account_parent FOREIGN KEY (parentaccountid) 
        REFERENCES acct.account (accountid)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_fiscalyear_client'
                      AND conrelid = 'acct.fiscalyear'::regclass) THEN
        ALTER TABLE acct.fiscalyear ADD CONSTRAINT fk_fiscalyear_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_invoice_client'
                      AND conrelid = 'acct.invoice'::regclass) THEN
        ALTER TABLE acct.invoice ADD CONSTRAINT fk_invoice_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_invoice_engagement'
                      AND conrelid = 'acct.invoice'::regclass) THEN
        ALTER TABLE acct.invoice ADD CONSTRAINT fk_invoice_engagement FOREIGN KEY (engagementid) 
        REFERENCES client.engagement (engagementid)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_invoice_province'
                      AND conrelid = 'acct.invoice'::regclass) THEN
        ALTER TABLE acct.invoice ADD CONSTRAINT fk_invoice_province FOREIGN KEY (provincecode) 
        REFERENCES ref.province (provincecode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_invoiceline_invoice'
                      AND conrelid = 'acct.invoiceline'::regclass) THEN
        ALTER TABLE acct.invoiceline ADD CONSTRAINT fk_invoiceline_invoice FOREIGN KEY (invoiceid) 
        REFERENCES acct.invoice (invoiceid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_journalentry_client'
                      AND conrelid = 'acct.journalentry'::regclass) THEN
        ALTER TABLE acct.journalentry ADD CONSTRAINT fk_journalentry_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_journalentry_fiscalyear'
                      AND conrelid = 'acct.journalentry'::regclass) THEN
        ALTER TABLE acct.journalentry ADD CONSTRAINT fk_journalentry_fiscalyear FOREIGN KEY (fiscalyearid) 
        REFERENCES acct.fiscalyear (fiscalyearid)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_journalentry_reversal'
                      AND conrelid = 'acct.journalentry'::regclass) THEN
        ALTER TABLE acct.journalentry ADD CONSTRAINT fk_journalentry_reversal FOREIGN KEY (reversedbyentryid) 
        REFERENCES acct.journalentry (journalentryid)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_journalline_account'
                      AND conrelid = 'acct.journalline'::regclass) THEN
        ALTER TABLE acct.journalline ADD CONSTRAINT fk_journalline_account FOREIGN KEY (accountid) 
        REFERENCES acct.account (accountid)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_journalline_journalentry'
                      AND conrelid = 'acct.journalline'::regclass) THEN
        ALTER TABLE acct.journalline ADD CONSTRAINT fk_journalline_journalentry FOREIGN KEY (journalentryid) 
        REFERENCES acct.journalentry (journalentryid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_payment_invoice'
                      AND conrelid = 'acct.payment'::regclass) THEN
        ALTER TABLE acct.payment ADD CONSTRAINT fk_payment_invoice FOREIGN KEY (invoiceid) 
        REFERENCES acct.invoice (invoiceid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_returnstatushistory_t1return'
                      AND conrelid = 'audit.returnstatushistory'::regclass) THEN
        ALTER TABLE audit.returnstatushistory ADD CONSTRAINT fk_returnstatushistory_t1return FOREIGN KEY (t1returnid) 
        REFERENCES tax.t1return (t1returnid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_client_province'
                      AND conrelid = 'client.client'::regclass) THEN
        ALTER TABLE client.client ADD CONSTRAINT fk_client_province FOREIGN KEY (provincecode) 
        REFERENCES ref.province (provincecode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_clientaddress_client'
                      AND conrelid = 'client.clientaddress'::regclass) THEN
        ALTER TABLE client.clientaddress ADD CONSTRAINT fk_clientaddress_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_clientaddress_province'
                      AND conrelid = 'client.clientaddress'::regclass) THEN
        ALTER TABLE client.clientaddress ADD CONSTRAINT fk_clientaddress_province FOREIGN KEY (provincecode) 
        REFERENCES ref.province (provincecode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_clientcontact_client'
                      AND conrelid = 'client.clientcontact'::regclass) THEN
        ALTER TABLE client.clientcontact ADD CONSTRAINT fk_clientcontact_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_engagement_client'
                      AND conrelid = 'client.engagement'::regclass) THEN
        ALTER TABLE client.engagement ADD CONSTRAINT fk_engagement_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_engagement_practitioner'
                      AND conrelid = 'client.engagement'::regclass) THEN
        ALTER TABLE client.engagement ADD CONSTRAINT fk_engagement_practitioner FOREIGN KEY (practitionerid) 
        REFERENCES client.practitioner (practitionerid)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_engagement_taxyear'
                      AND conrelid = 'client.engagement'::regclass) THEN
        ALTER TABLE client.engagement ADD CONSTRAINT fk_engagement_taxyear FOREIGN KEY (taxyear) 
        REFERENCES ref.taxyear (taxyear)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_employee_client'
                      AND conrelid = 'payroll.employee'::regclass) THEN
        ALTER TABLE payroll.employee ADD CONSTRAINT fk_employee_client FOREIGN KEY (employerclientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_employee_province'
                      AND conrelid = 'payroll.employee'::regclass) THEN
        ALTER TABLE payroll.employee ADD CONSTRAINT fk_employee_province FOREIGN KEY (provinceofemployment) 
        REFERENCES ref.province (provincecode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_payperiod_client'
                      AND conrelid = 'payroll.payperiod'::regclass) THEN
        ALTER TABLE payroll.payperiod ADD CONSTRAINT fk_payperiod_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_payperiod_taxyear'
                      AND conrelid = 'payroll.payperiod'::regclass) THEN
        ALTER TABLE payroll.payperiod ADD CONSTRAINT fk_payperiod_taxyear FOREIGN KEY (taxyear) 
        REFERENCES ref.taxyear (taxyear)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_paystub_employee'
                      AND conrelid = 'payroll.paystub'::regclass) THEN
        ALTER TABLE payroll.paystub ADD CONSTRAINT fk_paystub_employee FOREIGN KEY (employeeid) 
        REFERENCES payroll.employee (employeeid)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_paystub_payperiod'
                      AND conrelid = 'payroll.paystub'::regclass) THEN
        ALTER TABLE payroll.paystub ADD CONSTRAINT fk_paystub_payperiod FOREIGN KEY (payperiodid) 
        REFERENCES payroll.payperiod (payperiodid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_remittance_client'
                      AND conrelid = 'payroll.remittance'::regclass) THEN
        ALTER TABLE payroll.remittance ADD CONSTRAINT fk_remittance_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_jurisdiction_province'
                      AND conrelid = 'ref.jurisdiction'::regclass) THEN
        ALTER TABLE ref.jurisdiction ADD CONSTRAINT fk_jurisdiction_province FOREIGN KEY (provincecode) 
        REFERENCES ref.province (provincecode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_nonrefundablecredit_jurisdiction'
                      AND conrelid = 'ref.nonrefundablecredit'::regclass) THEN
        ALTER TABLE ref.nonrefundablecredit ADD CONSTRAINT fk_nonrefundablecredit_jurisdiction FOREIGN KEY (jurisdictioncode) 
        REFERENCES ref.jurisdiction (jurisdictioncode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_nonrefundablecredit_taxyear'
                      AND conrelid = 'ref.nonrefundablecredit'::regclass) THEN
        ALTER TABLE ref.nonrefundablecredit ADD CONSTRAINT fk_nonrefundablecredit_taxyear FOREIGN KEY (taxyear) 
        REFERENCES ref.taxyear (taxyear)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_payrollrate_taxyear'
                      AND conrelid = 'ref.payrollrate'::regclass) THEN
        ALTER TABLE ref.payrollrate ADD CONSTRAINT fk_payrollrate_taxyear FOREIGN KEY (taxyear) 
        REFERENCES ref.taxyear (taxyear)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_salestaxrate_province'
                      AND conrelid = 'ref.salestaxrate'::regclass) THEN
        ALTER TABLE ref.salestaxrate ADD CONSTRAINT fk_salestaxrate_province FOREIGN KEY (provincecode) 
        REFERENCES ref.province (provincecode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_slipboxdefinition_sliptype'
                      AND conrelid = 'ref.slipboxdefinition'::regclass) THEN
        ALTER TABLE ref.slipboxdefinition ADD CONSTRAINT fk_slipboxdefinition_sliptype FOREIGN KEY (sliptypecode) 
        REFERENCES ref.sliptype (sliptypecode)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_statutoryholiday_jurisdiction'
                      AND conrelid = 'ref.statutoryholiday'::regclass) THEN
        ALTER TABLE ref.statutoryholiday ADD CONSTRAINT fk_statutoryholiday_jurisdiction FOREIGN KEY (jurisdictioncode) 
        REFERENCES ref.jurisdiction (jurisdictioncode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_taxbracket_jurisdiction'
                      AND conrelid = 'ref.taxbracket'::regclass) THEN
        ALTER TABLE ref.taxbracket ADD CONSTRAINT fk_taxbracket_jurisdiction FOREIGN KEY (jurisdictioncode) 
        REFERENCES ref.jurisdiction (jurisdictioncode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_taxbracket_taxyear'
                      AND conrelid = 'ref.taxbracket'::regclass) THEN
        ALTER TABLE ref.taxbracket ADD CONSTRAINT fk_taxbracket_taxyear FOREIGN KEY (taxyear) 
        REFERENCES ref.taxyear (taxyear)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_assessment_t1return'
                      AND conrelid = 'tax.assessment'::regclass) THEN
        ALTER TABLE tax.assessment ADD CONSTRAINT fk_assessment_t1return FOREIGN KEY (t1returnid) 
        REFERENCES tax.t1return (t1returnid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_creditclaim_credit'
                      AND conrelid = 'tax.creditclaim'::regclass) THEN
        ALTER TABLE tax.creditclaim ADD CONSTRAINT fk_creditclaim_credit FOREIGN KEY (taxyear, jurisdictioncode, creditcode) 
        REFERENCES ref.nonrefundablecredit (taxyear, jurisdictioncode, creditcode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_creditclaim_t1return'
                      AND conrelid = 'tax.creditclaim'::regclass) THEN
        ALTER TABLE tax.creditclaim ADD CONSTRAINT fk_creditclaim_t1return FOREIGN KEY (t1returnid) 
        REFERENCES tax.t1return (t1returnid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_gsthstreturn_client'
                      AND conrelid = 'tax.gsthstreturn'::regclass) THEN
        ALTER TABLE tax.gsthstreturn ADD CONSTRAINT fk_gsthstreturn_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_gsthstreturn_frequency'
                      AND conrelid = 'tax.gsthstreturn'::regclass) THEN
        ALTER TABLE tax.gsthstreturn ADD CONSTRAINT fk_gsthstreturn_frequency FOREIGN KEY (frequencycode) 
        REFERENCES ref.filingfrequency (frequencycode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_installment_client'
                      AND conrelid = 'tax.installment'::regclass) THEN
        ALTER TABLE tax.installment ADD CONSTRAINT fk_installment_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_installment_taxyear'
                      AND conrelid = 'tax.installment'::regclass) THEN
        ALTER TABLE tax.installment ADD CONSTRAINT fk_installment_taxyear FOREIGN KEY (taxyear) 
        REFERENCES ref.taxyear (taxyear)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_rrsp_client'
                      AND conrelid = 'tax.rrspcontribution'::regclass) THEN
        ALTER TABLE tax.rrspcontribution ADD CONSTRAINT fk_rrsp_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_rrsp_taxyear'
                      AND conrelid = 'tax.rrspcontribution'::regclass) THEN
        ALTER TABLE tax.rrspcontribution ADD CONSTRAINT fk_rrsp_taxyear FOREIGN KEY (taxyear) 
        REFERENCES ref.taxyear (taxyear)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_slip_client'
                      AND conrelid = 'tax.slip'::regclass) THEN
        ALTER TABLE tax.slip ADD CONSTRAINT fk_slip_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_slip_sliptype'
                      AND conrelid = 'tax.slip'::regclass) THEN
        ALTER TABLE tax.slip ADD CONSTRAINT fk_slip_sliptype FOREIGN KEY (sliptypecode) 
        REFERENCES ref.sliptype (sliptypecode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_slip_taxyear'
                      AND conrelid = 'tax.slip'::regclass) THEN
        ALTER TABLE tax.slip ADD CONSTRAINT fk_slip_taxyear FOREIGN KEY (taxyear) 
        REFERENCES ref.taxyear (taxyear)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_slipbox_definition'
                      AND conrelid = 'tax.slipbox'::regclass) THEN
        ALTER TABLE tax.slipbox ADD CONSTRAINT fk_slipbox_definition FOREIGN KEY (sliptypecode, boxnumber) 
        REFERENCES ref.slipboxdefinition (sliptypecode, boxnumber)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_slipbox_slip'
                      AND conrelid = 'tax.slipbox'::regclass) THEN
        ALTER TABLE tax.slipbox ADD CONSTRAINT fk_slipbox_slip FOREIGN KEY (slipid, sliptypecode) 
        REFERENCES tax.slip (slipid, sliptypecode)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_t1return_client'
                      AND conrelid = 'tax.t1return'::regclass) THEN
        ALTER TABLE tax.t1return ADD CONSTRAINT fk_t1return_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_t1return_province'
                      AND conrelid = 'tax.t1return'::regclass) THEN
        ALTER TABLE tax.t1return ADD CONSTRAINT fk_t1return_province FOREIGN KEY (provinceofresidence) 
        REFERENCES ref.province (provincecode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_t1return_taxyear'
                      AND conrelid = 'tax.t1return'::regclass) THEN
        ALTER TABLE tax.t1return ADD CONSTRAINT fk_t1return_taxyear FOREIGN KEY (taxyear) 
        REFERENCES ref.taxyear (taxyear)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_t2return_client'
                      AND conrelid = 'tax.t2return'::regclass) THEN
        ALTER TABLE tax.t2return ADD CONSTRAINT fk_t2return_client FOREIGN KEY (clientid) 
        REFERENCES client.client (clientid)
        ON UPDATE NO ACTION
        ON DELETE CASCADE;
    END IF;
END $do$;

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'fk_t2return_province'
                      AND conrelid = 'tax.t2return'::regclass) THEN
        ALTER TABLE tax.t2return ADD CONSTRAINT fk_t2return_province FOREIGN KEY (provinceofoperation) 
        REFERENCES ref.province (provincecode)
        ON UPDATE NO ACTION
        ON DELETE NO ACTION;
    END IF;
END $do$;
