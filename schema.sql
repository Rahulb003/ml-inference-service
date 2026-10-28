-- Banking data warehouse: staging layer + star schema + ETL control tables.
-- PostgreSQL 16. Oracle equivalents are noted where syntax differs (see README).

DROP SCHEMA IF EXISTS stg CASCADE;
DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA stg;   -- raw daily extract, loaded as text, truncated every run
CREATE SCHEMA dw;    -- cleaned, conformed star schema

-- ---------- staging (everything as text: the ETL validates, not the loader)
CREATE TABLE stg.branches     (branch_code text, branch_name text, city text, state text);
CREATE TABLE stg.customers    (customer_id text, full_name text, segment text, city text, home_branch text, kyc_date text);
CREATE TABLE stg.accounts     (account_id text, customer_id text, account_type text, branch_code text, opened_on text);
CREATE TABLE stg.transactions (txn_id text, account_id text, txn_ts text, channel text, direction text, amount text, currency text);

-- ---------- ETL control: one row per run, plus every rejected record with its reason
CREATE TABLE dw.etl_run (
    run_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,   -- Oracle: sequence or IDENTITY (12c+)
    batch_name    text NOT NULL,
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    status        text NOT NULL DEFAULT 'RUNNING' CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    rows_read     int,
    rows_loaded   int,
    rows_rejected int,
    error_message text
);
CREATE TABLE dw.etl_reject (
    run_id     bigint REFERENCES dw.etl_run(run_id),
    source     text NOT NULL,
    record_key text,
    reason     text NOT NULL,
    raw_row    jsonb
);

-- ---------- dimensions
CREATE TABLE dw.dim_date (
    date_key   int PRIMARY KEY,            -- yyyymmdd
    full_date  date NOT NULL UNIQUE,
    day_name   text, month_num int, month_name text, quarter int, year int,
    fiscal_year text,                      -- Indian FY, Apr-Mar
    is_weekend boolean
);
CREATE TABLE dw.dim_branch (
    branch_key  int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_code text NOT NULL UNIQUE, branch_name text, city text, state text
);
-- SCD Type 2: a change in segment or city closes the old row and opens a new one
CREATE TABLE dw.dim_customer (
    customer_key int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  text NOT NULL,
    full_name    text, segment text, city text, home_branch text, kyc_date date,
    valid_from   date NOT NULL,
    valid_to     date NOT NULL DEFAULT '9999-12-31',
    is_current   boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX ux_dim_customer_current ON dw.dim_customer (customer_id) WHERE is_current;
CREATE TABLE dw.dim_account (
    account_key  int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id   text NOT NULL UNIQUE,
    customer_id  text NOT NULL, account_type text, branch_code text, opened_on date
);
CREATE TABLE dw.dim_channel (
    channel_key  int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_code text NOT NULL UNIQUE, channel_group text
);
INSERT INTO dw.dim_channel (channel_code, channel_group) VALUES
    ('UPI', 'Digital'), ('NEFT', 'Digital'), ('IMPS', 'Digital'), ('RTGS', 'Digital'),
    ('CARD', 'Digital'), ('ATM', 'Self-service'), ('BRANCH', 'Assisted');

-- ---------- fact
CREATE TABLE dw.fact_transaction (
    txn_id       text PRIMARY KEY,
    date_key     int NOT NULL REFERENCES dw.dim_date(date_key),
    account_key  int NOT NULL REFERENCES dw.dim_account(account_key),
    customer_key int NOT NULL REFERENCES dw.dim_customer(customer_key),
    branch_key   int NOT NULL REFERENCES dw.dim_branch(branch_key),
    channel_key  int NOT NULL REFERENCES dw.dim_channel(channel_key),
    txn_ts       timestamp NOT NULL,
    direction    char(2) NOT NULL CHECK (direction IN ('DR', 'CR')),
    amount       numeric(14, 2) NOT NULL CHECK (amount > 0),
    run_id       bigint NOT NULL REFERENCES dw.etl_run(run_id)
);
-- indexes are created by indexes.sql so the benchmark can measure them
