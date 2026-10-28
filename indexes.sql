-- Indexes for the most common access paths (created after the tables; measured in benchmark.py)
CREATE INDEX IF NOT EXISTS ix_fact_date        ON dw.fact_transaction (date_key);
CREATE INDEX IF NOT EXISTS ix_fact_account_ts  ON dw.fact_transaction (account_key, txn_ts);
CREATE INDEX IF NOT EXISTS ix_fact_branch_date ON dw.fact_transaction (branch_key, date_key);
CREATE INDEX IF NOT EXISTS ix_reject_run       ON dw.etl_reject (run_id, reason);
