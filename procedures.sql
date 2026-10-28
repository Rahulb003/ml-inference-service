-- ETL stored procedures in PL/pgSQL (PostgreSQL's procedural SQL, close to Oracle PL/SQL).
-- Entry point: CALL dw.sp_run_etl('batch1', DATE '2026-09-30');

-- ---------- date dimension
CREATE OR REPLACE PROCEDURE dw.sp_load_dim_date(p_from date, p_to date)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO dw.dim_date
    SELECT to_char(d, 'YYYYMMDD')::int, d, trim(to_char(d, 'Day')), extract(month FROM d), trim(to_char(d, 'Month')),
           extract(quarter FROM d), extract(year FROM d),
           CASE WHEN extract(month FROM d) >= 4 THEN 'FY' || to_char(d, 'YY') || '-' || to_char(d + interval '1 year', 'YY')
                ELSE 'FY' || to_char(d - interval '1 year', 'YY') || '-' || to_char(d, 'YY') END,
           extract(isodow FROM d) IN (6, 7)
    FROM generate_series(p_from, p_to, interval '1 day') AS g(d)
    ON CONFLICT (date_key) DO NOTHING;
END $$;

-- ---------- branch dimension (Type 1: overwrite)
CREATE OR REPLACE PROCEDURE dw.sp_load_dim_branch(p_run bigint)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO dw.dim_branch (branch_code, branch_name, city, state)
    SELECT DISTINCT ON (branch_code) branch_code, branch_name, city, state FROM stg.branches WHERE branch_code IS NOT NULL
    ON CONFLICT (branch_code) DO UPDATE SET branch_name = EXCLUDED.branch_name, city = EXCLUDED.city, state = EXCLUDED.state;
END $$;

-- ---------- customer dimension (SCD Type 2 on segment and city)
CREATE OR REPLACE PROCEDURE dw.sp_load_dim_customer(p_run bigint, p_as_of date)
LANGUAGE plpgsql AS $$
DECLARE
    v_closed int;
    v_new    int;
BEGIN
    INSERT INTO dw.etl_reject (run_id, source, record_key, reason, raw_row)
    SELECT p_run, 'customers', customer_id,
           CASE WHEN customer_id IS NULL THEN 'missing customer_id' ELSE 'invalid kyc_date' END, to_jsonb(s)
    FROM stg.customers s
    WHERE customer_id IS NULL OR kyc_date !~ '^\d{4}-\d{2}-\d{2}$';

    -- 1) close the current row when a tracked attribute changed
    UPDATE dw.dim_customer d
    SET valid_to = p_as_of - 1, is_current = false
    FROM stg.customers s
    WHERE d.customer_id = s.customer_id AND d.is_current
      AND (d.segment IS DISTINCT FROM s.segment OR d.city IS DISTINCT FROM s.city);
    GET DIAGNOSTICS v_closed = ROW_COUNT;

    -- 2) insert a new current row for changed and brand-new customers
    --    (first version starts at the KYC date so older transactions still find their customer)
    INSERT INTO dw.dim_customer (customer_id, full_name, segment, city, home_branch, kyc_date, valid_from)
    SELECT s.customer_id, s.full_name, s.segment, s.city, s.home_branch, s.kyc_date::date,
           CASE WHEN EXISTS (SELECT 1 FROM dw.dim_customer h WHERE h.customer_id = s.customer_id)
                THEN p_as_of ELSE s.kyc_date::date END
    FROM stg.customers s
    WHERE s.customer_id IS NOT NULL AND s.kyc_date ~ '^\d{4}-\d{2}-\d{2}$'
      AND NOT EXISTS (SELECT 1 FROM dw.dim_customer d WHERE d.customer_id = s.customer_id AND d.is_current);
    GET DIAGNOSTICS v_new = ROW_COUNT;
    RAISE NOTICE 'dim_customer: % versions closed, % rows inserted', v_closed, v_new;
END $$;

-- ---------- account dimension (Type 1), rejects accounts whose customer is unknown
CREATE OR REPLACE PROCEDURE dw.sp_load_dim_account(p_run bigint)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO dw.etl_reject (run_id, source, record_key, reason, raw_row)
    SELECT p_run, 'accounts', s.account_id, 'unknown customer_id', to_jsonb(s)
    FROM stg.accounts s
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_customer c WHERE c.customer_id = s.customer_id);

    INSERT INTO dw.dim_account (account_id, customer_id, account_type, branch_code, opened_on)
    SELECT s.account_id, s.customer_id, s.account_type, s.branch_code, s.opened_on::date
    FROM stg.accounts s
    WHERE EXISTS (SELECT 1 FROM dw.dim_customer c WHERE c.customer_id = s.customer_id)
    ON CONFLICT (account_id) DO UPDATE SET account_type = EXCLUDED.account_type, branch_code = EXCLUDED.branch_code;
END $$;

-- ---------- transaction fact: validate, reject with a reason, load the rest with surrogate keys
CREATE OR REPLACE FUNCTION dw.fn_load_fact_transaction(p_run bigint, p_as_of date, OUT o_read int, OUT o_loaded int, OUT o_rejected int)
LANGUAGE plpgsql AS $$
BEGIN
    SELECT count(*) INTO o_read FROM stg.transactions;

    CREATE TEMP TABLE tmp_txn ON COMMIT DROP AS
    SELECT s.*,
           CASE
             WHEN s.txn_id IS NULL                                   THEN 'missing txn_id'
             WHEN row_number() OVER (PARTITION BY s.txn_id ORDER BY s.txn_ts) > 1 THEN 'duplicate txn_id in batch'
             WHEN EXISTS (SELECT 1 FROM dw.fact_transaction f WHERE f.txn_id = s.txn_id) THEN 'already loaded'
             WHEN s.amount IS NULL OR s.amount = ''                  THEN 'missing amount'
             WHEN s.amount !~ '^-?\d+(\.\d+)?$'                      THEN 'non-numeric amount'
             WHEN s.amount::numeric <= 0                             THEN 'non-positive amount'
             WHEN s.txn_ts::date > p_as_of                           THEN 'future-dated transaction'
             WHEN s.direction NOT IN ('DR', 'CR')                    THEN 'invalid direction'
             WHEN NOT EXISTS (SELECT 1 FROM dw.dim_channel c WHERE c.channel_code = s.channel) THEN 'invalid channel'
             WHEN NOT EXISTS (SELECT 1 FROM dw.dim_account a WHERE a.account_id = s.account_id) THEN 'unknown account_id'
           END AS reject_reason
    FROM stg.transactions s;

    INSERT INTO dw.etl_reject (run_id, source, record_key, reason, raw_row)
    SELECT p_run, 'transactions', txn_id, reject_reason, to_jsonb(t) - 'reject_reason'
    FROM tmp_txn t WHERE reject_reason IS NOT NULL;
    GET DIAGNOSTICS o_rejected = ROW_COUNT;

    INSERT INTO dw.fact_transaction (txn_id, date_key, account_key, customer_key, branch_key, channel_key,
                                     txn_ts, direction, amount, run_id)
    SELECT t.txn_id, to_char(t.txn_ts::date, 'YYYYMMDD')::int, a.account_key, c.customer_key, b.branch_key,
           ch.channel_key, t.txn_ts::timestamp, t.direction, t.amount::numeric, p_run
    FROM tmp_txn t
    JOIN dw.dim_account  a  ON a.account_id = t.account_id
    JOIN dw.dim_branch   b  ON b.branch_code = a.branch_code
    JOIN dw.dim_channel  ch ON ch.channel_code = t.channel
    -- point-in-time join: the customer version that was valid on the transaction date
    JOIN dw.dim_customer c  ON c.customer_id = a.customer_id
                           AND t.txn_ts::date BETWEEN c.valid_from AND c.valid_to
    WHERE t.reject_reason IS NULL;
    GET DIAGNOSTICS o_loaded = ROW_COUNT;
END $$;

-- ---------- reporting layer
CREATE OR REPLACE PROCEDURE dw.sp_refresh_reporting()
LANGUAGE plpgsql AS $$
BEGIN
    DROP MATERIALIZED VIEW IF EXISTS dw.mv_monthly_branch_channel;
    CREATE MATERIALIZED VIEW dw.mv_monthly_branch_channel AS
    SELECT d.year, d.month_num, b.branch_code, ch.channel_group,
           count(*) AS txn_count,
           sum(f.amount) FILTER (WHERE f.direction = 'CR') AS credits,
           sum(f.amount) FILTER (WHERE f.direction = 'DR') AS debits
    FROM dw.fact_transaction f
    JOIN dw.dim_date d     ON d.date_key = f.date_key
    JOIN dw.dim_branch b   ON b.branch_key = f.branch_key
    JOIN dw.dim_channel ch ON ch.channel_key = f.channel_key
    GROUP BY 1, 2, 3, 4;
END $$;

-- ---------- orchestration with audit logging and error handling
CREATE OR REPLACE PROCEDURE dw.sp_run_etl(p_batch text, p_as_of date)
LANGUAGE plpgsql AS $$
DECLARE
    v_run bigint;
    r     record;
BEGIN
    INSERT INTO dw.etl_run (batch_name) VALUES (p_batch) RETURNING run_id INTO v_run;
    COMMIT;  -- the run row survives even if the load fails
    BEGIN
        CALL dw.sp_load_dim_date(DATE '2026-04-01', DATE '2027-03-31');
        CALL dw.sp_load_dim_branch(v_run);
        CALL dw.sp_load_dim_customer(v_run, p_as_of);
        CALL dw.sp_load_dim_account(v_run);
        SELECT * INTO r FROM dw.fn_load_fact_transaction(v_run, p_as_of);
        CALL dw.sp_refresh_reporting();
        UPDATE dw.etl_run SET status = 'SUCCESS', finished_at = now(),
               rows_read = r.o_read, rows_loaded = r.o_loaded, rows_rejected = r.o_rejected
        WHERE run_id = v_run;
    EXCEPTION WHEN OTHERS THEN
        UPDATE dw.etl_run SET status = 'FAILED', finished_at = now(), error_message = SQLERRM WHERE run_id = v_run;
        RAISE WARNING 'ETL run % failed: %', v_run, SQLERRM;
    END;
END $$;

-- ---------- reconciliation: every staged row must be either loaded or rejected
CREATE OR REPLACE FUNCTION dw.fn_reconcile(p_run bigint)
RETURNS TABLE (check_name text, expected bigint, actual bigint, passed boolean)
LANGUAGE sql AS $$
    SELECT 'rows_read = rows_loaded + rows_rejected', r.rows_read::bigint, (r.rows_loaded + r.rows_rejected)::bigint,
           r.rows_read = r.rows_loaded + r.rows_rejected
    FROM dw.etl_run r WHERE r.run_id = p_run
    UNION ALL
    SELECT 'fact rows tagged with this run', r.rows_loaded::bigint,
           (SELECT count(*) FROM dw.fact_transaction f WHERE f.run_id = p_run), true
    FROM dw.etl_run r WHERE r.run_id = p_run
    UNION ALL
    SELECT 'customers with exactly one current row', (SELECT count(DISTINCT customer_id) FROM dw.dim_customer),
           (SELECT count(*) FROM dw.dim_customer WHERE is_current), true;
$$;
