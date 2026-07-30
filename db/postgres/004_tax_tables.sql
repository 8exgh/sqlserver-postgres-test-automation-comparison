/*==============================================================================
  004 - Tax filings  [tax]

  PostgreSQL port of db/sqlserver/004_tax_tables.sql.
  Bootstrapped from the AWS SCT output in db/postgres/generated/, then corrected
  by hand. See db/README.md for what SCT got wrong and why.
==============================================================================*/

CREATE TABLE IF NOT EXISTS tax.assessment(
    assessmentid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    t1returnid INTEGER NOT NULL,
    assessmenttype VARCHAR(20) NOT NULL,
    assessedon TIMESTAMP(3) WITHOUT TIME ZONE NOT NULL DEFAULT timezone('UTC', LOCALTIMESTAMP(6)),
    taxableincome NUMERIC(19,2) NOT NULL,
    federaltax NUMERIC(19,2) NOT NULL,
    provincialtax NUMERIC(19,2) NOT NULL,
    totalpayable NUMERIC(19,2) NOT NULL,
    balanceowing NUMERIC(19,2) NOT NULL,
    calculationnotes VARCHAR(400)
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS tax.creditclaim(
    creditclaimid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    t1returnid INTEGER NOT NULL,
    taxyear SMALLINT NOT NULL,
    jurisdictioncode CHAR(2) NOT NULL,
    creditcode VARCHAR(20) NOT NULL,
    claimedamount NUMERIC(19,2) NOT NULL
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS tax.gsthstreturn(
    gsthstreturnid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientid INTEGER NOT NULL,
    periodstart DATE NOT NULL,
    periodend DATE NOT NULL,
    frequencycode VARCHAR(10) NOT NULL,
    line101sales NUMERIC(19,2) NOT NULL DEFAULT (0),
    line105taxcollected NUMERIC(19,2) NOT NULL DEFAULT (0),
    line108inputtaxcredits NUMERIC(19,2) NOT NULL DEFAULT (0),
    line109nettax NUMERIC(20,2) NOT NULL GENERATED ALWAYS AS (line105taxcollected - line108inputtaxcredits) STORED,
    paymentsmade NUMERIC(19,2) NOT NULL DEFAULT (0),
    balancedue NUMERIC(21,2) NOT NULL GENERATED ALWAYS AS ((line105taxcollected - line108inputtaxcredits) - paymentsmade) STORED,
    filingduedate DATE NOT NULL,
    filedat TIMESTAMP(3) WITHOUT TIME ZONE,
    status VARCHAR(20) NOT NULL DEFAULT 'Open'
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS tax.installment(
    installmentid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientid INTEGER NOT NULL,
    taxyear SMALLINT NOT NULL,
    duedate DATE NOT NULL,
    amountdue NUMERIC(19,2) NOT NULL,
    amountpaid NUMERIC(19,2) NOT NULL DEFAULT (0),
    paiddate DATE
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS tax.rrspcontribution(
    rrspcontributionid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientid INTEGER NOT NULL,
    taxyear SMALLINT NOT NULL,
    contributiondate DATE NOT NULL,
    amount NUMERIC(19,2) NOT NULL,
    isfirst60days NUMERIC(1,0) NOT NULL DEFAULT (0),
    issuername VARCHAR(150) NOT NULL
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS tax.slip(
    slipid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientid INTEGER NOT NULL,
    taxyear SMALLINT NOT NULL,
    sliptypecode VARCHAR(10) NOT NULL,
    issuername VARCHAR(150) NOT NULL,
    issuerbusinessnumber CHAR(9),
    slipreference VARCHAR(40) NOT NULL,
    receiveddate DATE,
    isamended NUMERIC(1,0) NOT NULL DEFAULT (0)
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS tax.slipbox(
    slipid INTEGER NOT NULL,
    sliptypecode VARCHAR(10) NOT NULL,
    boxnumber VARCHAR(10) NOT NULL,
    amount NUMERIC(19,2) NOT NULL
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS tax.t1return(
    t1returnid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientid INTEGER NOT NULL,
    taxyear SMALLINT NOT NULL,
    provinceofresidence CHAR(2) NOT NULL,
    filingstatus VARCHAR(20) NOT NULL DEFAULT 'Draft',
    maritalstatus VARCHAR(20),
    isselfemployed NUMERIC(1,0) NOT NULL DEFAULT (0),
    employmentincome NUMERIC(19,2) NOT NULL DEFAULT (0),
    investmentincome NUMERIC(19,2) NOT NULL DEFAULT (0),
    selfemploymentincome NUMERIC(19,2) NOT NULL DEFAULT (0),
    pensionincome NUMERIC(19,2) NOT NULL DEFAULT (0),
    otherincome NUMERIC(19,2) NOT NULL DEFAULT (0),
    rrspdeduction NUMERIC(19,2) NOT NULL DEFAULT (0),
    uniondues NUMERIC(19,2) NOT NULL DEFAULT (0),
    childcareexpenses NUMERIC(19,2) NOT NULL DEFAULT (0),
    otherdeductions NUMERIC(19,2) NOT NULL DEFAULT (0),
    losscarryforward NUMERIC(19,2) NOT NULL DEFAULT (0),
    totalincome NUMERIC(23,2) NOT NULL GENERATED ALWAYS AS ((((employmentincome + investmentincome) + selfemploymentincome) + pensionincome) + otherincome) STORED,
    totaldeductions NUMERIC(22,2) NOT NULL GENERATED ALWAYS AS (((rrspdeduction + uniondues) + childcareexpenses) + otherdeductions) STORED,
    netincome NUMERIC(27,2) NOT NULL GENERATED ALWAYS AS ((((((((employmentincome + investmentincome) + selfemploymentincome) + pensionincome) + otherincome) - rrspdeduction) - uniondues) - childcareexpenses) - otherdeductions) STORED,
    taxableincome NUMERIC(28,2) NOT NULL GENERATED ALWAYS AS ((CASE WHEN employmentincome + investmentincome + selfemploymentincome + pensionincome + otherincome - rrspdeduction - uniondues - childcareexpenses - otherdeductions - losscarryforward < 0 THEN 0 ELSE employmentincome + investmentincome + selfemploymentincome + pensionincome + otherincome - rrspdeduction - uniondues - childcareexpenses - otherdeductions - losscarryforward END)::numeric(28,2)) STORED,
    federaltax NUMERIC(19,2) NOT NULL DEFAULT (0),
    provincialtax NUMERIC(19,2) NOT NULL DEFAULT (0),
    federalcredits NUMERIC(19,2) NOT NULL DEFAULT (0),
    provincialcredits NUMERIC(19,2) NOT NULL DEFAULT (0),
    cppselfemployment NUMERIC(19,2) NOT NULL DEFAULT (0),
    eiselfemployment NUMERIC(19,2) NOT NULL DEFAULT (0),
    netfederaltax NUMERIC(20,2) NOT NULL GENERATED ALWAYS AS ((CASE WHEN federaltax - federalcredits < 0 THEN 0 ELSE federaltax - federalcredits END)::numeric(20,2)) STORED,
    netprovincialtax NUMERIC(20,2) NOT NULL GENERATED ALWAYS AS ((CASE WHEN provincialtax - provincialcredits < 0 THEN 0 ELSE provincialtax - provincialcredits END)::numeric(20,2)) STORED,
    taxwithheld NUMERIC(19,2) NOT NULL DEFAULT (0),
    installmentspaid NUMERIC(19,2) NOT NULL DEFAULT (0),
    totalpayable NUMERIC(19,2) NOT NULL DEFAULT (0),
    balanceowing NUMERIC(19,2) NOT NULL DEFAULT (0),
    datefiled DATE,
    calculatedat TIMESTAMP(3) WITHOUT TIME ZONE,
    assessedat TIMESTAMP(3) WITHOUT TIME ZONE,
    noticeofassessmentno VARCHAR(25),
    createdat TIMESTAMP(3) WITHOUT TIME ZONE NOT NULL DEFAULT timezone('UTC', LOCALTIMESTAMP(6))
)
        WITH (
        OIDS=FALSE
        );

CREATE TABLE IF NOT EXISTS tax.t2return(
    t2returnid INTEGER NOT NULL GENERATED ALWAYS AS IDENTITY,
    clientid INTEGER NOT NULL,
    fiscalyearstart DATE NOT NULL,
    fiscalyearend DATE NOT NULL,
    provinceofoperation CHAR(2) NOT NULL,
    filingstatus VARCHAR(20) NOT NULL DEFAULT 'Draft',
    isccpc NUMERIC(1,0) NOT NULL DEFAULT (1),
    grossrevenue NUMERIC(19,2) NOT NULL DEFAULT (0),
    totalexpenses NUMERIC(19,2) NOT NULL DEFAULT (0),
    netincomefortax NUMERIC(20,2) NOT NULL GENERATED ALWAYS AS (grossrevenue - totalexpenses) STORED,
    smallbusinessdeduction NUMERIC(19,2) NOT NULL DEFAULT (0),
    noncapitallossapplied NUMERIC(19,2) NOT NULL DEFAULT (0),
    taxableincome NUMERIC(21,2) NOT NULL GENERATED ALWAYS AS ((CASE WHEN grossrevenue - totalexpenses - noncapitallossapplied < 0 THEN 0 ELSE grossrevenue - totalexpenses - noncapitallossapplied END)::numeric(21,2)) STORED,
    federaltax NUMERIC(19,2) NOT NULL DEFAULT (0),
    provincialtax NUMERIC(19,2) NOT NULL DEFAULT (0),
    totaltaxpayable NUMERIC(20,2) NOT NULL GENERATED ALWAYS AS (federaltax + provincialtax) STORED,
    installmentspaid NUMERIC(19,2) NOT NULL DEFAULT (0),
    balanceowing NUMERIC(21,2) NOT NULL GENERATED ALWAYS AS ((federaltax + provincialtax) - installmentspaid) STORED,
    filingduedate DATE NOT NULL,
    datefiled DATE,
    createdat TIMESTAMP(3) WITHOUT TIME ZONE NOT NULL DEFAULT timezone('UTC', LOCALTIMESTAMP(6))
)
        WITH (
        OIDS=FALSE
        );
