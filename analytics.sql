-- Business questions answered from the warehouse (run: psql -f analytics.sql)

-- 1. Digital adoption: monthly transactions by channel group, with digital share
SELECT year, month_num,
       sum(txn_count) AS total_txns,
       round(100.0 * sum(txn_count) FILTER (WHERE channel_group = 'Digital') / sum(txn_count), 1) AS digital_share_pct
FROM dw.mv_monthly_branch_channel
GROUP BY year, month_num
ORDER BY year, month_num;

-- 2. Top 3 branches by net inflow (credits - debits) each month, ranked with a window function
SELECT * FROM (
    SELECT year, month_num, branch_code,
           sum(credits) - sum(debits) AS net_inflow,
           rank() OVER (PARTITION BY year, month_num ORDER BY sum(credits) - sum(debits) DESC) AS rnk
    FROM dw.mv_monthly_branch_channel
    GROUP BY year, month_num, branch_code
) x WHERE rnk <= 3
ORDER BY year, month_num, rnk;

-- 3. Dormant accounts: no transaction in the last 90 days of data
SELECT a.account_id, a.account_type, a.branch_code, max(f.txn_ts)::date AS last_txn
FROM dw.dim_account a
LEFT JOIN dw.fact_transaction f ON f.account_key = a.account_key
GROUP BY a.account_id, a.account_type, a.branch_code
HAVING max(f.txn_ts) IS NULL OR max(f.txn_ts) < (SELECT max(txn_ts) FROM dw.fact_transaction) - interval '90 days'
ORDER BY last_txn NULLS FIRST
LIMIT 20;

-- 4. Unusual transactions: more than 3 standard deviations above the account's own average
SELECT txn_id, account_key, txn_ts, amount, round(avg_amt, 2) AS account_avg
FROM (
    SELECT f.*, avg(amount) OVER w AS avg_amt, stddev_samp(amount) OVER w AS sd_amt, count(*) OVER w AS n
    FROM dw.fact_transaction f
    WINDOW w AS (PARTITION BY account_key)
) x
WHERE n >= 10 AND amount > avg_amt + 3 * sd_amt
ORDER BY amount DESC
LIMIT 20;

-- 5. Running net flow per account (cumulative credits - debits)
SELECT account_key, txn_ts, direction, amount,
       sum(CASE WHEN direction = 'CR' THEN amount ELSE -amount END)
           OVER (PARTITION BY account_key ORDER BY txn_ts ROWS UNBOUNDED PRECEDING) AS running_net_flow
FROM dw.fact_transaction
WHERE account_key = (SELECT min(account_key) FROM dw.fact_transaction)
ORDER BY txn_ts
LIMIT 20;

-- 6. SCD Type 2 history: customers whose segment or city changed
SELECT customer_id, segment, city, valid_from, valid_to, is_current
FROM dw.dim_customer
WHERE customer_id IN (SELECT customer_id FROM dw.dim_customer GROUP BY customer_id HAVING count(*) > 1)
ORDER BY customer_id, valid_from
LIMIT 20;

-- 7. Data-quality report for the latest ETL run (production support view)
SELECT r.run_id, r.batch_name, r.status, r.rows_read, r.rows_loaded, r.rows_rejected,
       round(100.0 * r.rows_rejected / nullif(r.rows_read, 0), 2) AS reject_pct,
       extract(epoch FROM r.finished_at - r.started_at)::numeric(8, 1) AS seconds
FROM dw.etl_run r
ORDER BY r.run_id DESC;
