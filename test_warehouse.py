"""End-to-end tests: build the warehouse from scratch, load both batches, check the results.

Needs a PostgreSQL database in DATABASE_URL (GitHub Actions starts one as a service).
Run: pytest -v
"""
import os
import subprocess
import sys

import psycopg
import pytest

DSN = os.environ.get("DATABASE_URL", "host=/var/tmp/pg port=5433 user=postgres dbname=postgres")


def sh(*args):
    subprocess.run([sys.executable, *args], check=True, capture_output=True, text=True)


@pytest.fixture(scope="session")
def db():
    sh("generate_data.py", "--batch", "1")
    sh("generate_data.py", "--batch", "2")
    sh("etl.py", "--init", "--batch", "1", "--as-of", "2026-09-30")
    sh("etl.py", "--batch", "2", "--as-of", "2026-10-01")
    with psycopg.connect(DSN, autocommit=True) as conn:
        yield conn


def one(conn, sql, *params):
    return conn.execute(sql, params).fetchone()[0]


def test_both_runs_succeeded(db):
    assert [r[0] for r in db.execute("SELECT status FROM dw.etl_run ORDER BY run_id")] == ["SUCCESS", "SUCCESS"]


def test_every_staged_row_is_loaded_or_rejected(db):
    for run_id, in db.execute("SELECT run_id FROM dw.etl_run"):
        for name, exp, act, ok in db.execute("SELECT * FROM dw.fn_reconcile(%s)", (run_id,)):
            assert exp == act, name


def test_each_planted_problem_is_rejected_with_a_reason(db):
    reasons = {r for r, in db.execute("SELECT DISTINCT reason FROM dw.etl_reject WHERE source = 'transactions'")}
    assert {"duplicate txn_id in batch", "missing amount", "non-positive amount", "unknown account_id",
            "future-dated transaction", "invalid channel"} <= reasons


def test_fact_has_no_bad_rows(db):
    assert one(db, "SELECT count(*) FROM dw.fact_transaction WHERE amount <= 0") == 0
    assert one(db, "SELECT count(*) FROM dw.fact_transaction WHERE txn_ts::date > '2026-10-01'") == 0
    assert one(db, "SELECT count(*) - count(DISTINCT txn_id) FROM dw.fact_transaction") == 0


def test_scd2_keeps_history_and_one_current_row(db):
    assert one(db, "SELECT count(*) FROM (SELECT customer_id FROM dw.dim_customer WHERE is_current "
                   "GROUP BY customer_id HAVING count(*) > 1) x") == 0
    changed = one(db, "SELECT count(*) FROM dw.dim_customer WHERE NOT is_current")
    assert changed > 50  # batch 2 moved ~120 customers
    assert one(db, "SELECT count(*) FROM dw.dim_customer WHERE NOT is_current AND valid_to >= valid_from") == changed


def test_point_in_time_join_uses_the_old_customer_version(db):
    # transactions before the change must point at the closed (old) version, not the current one
    bad = one(db, """SELECT count(*) FROM dw.fact_transaction f JOIN dw.dim_customer c USING (customer_key)
                     WHERE f.txn_ts::date NOT BETWEEN c.valid_from AND c.valid_to""")
    assert bad == 0


def test_rerunning_a_batch_is_idempotent(db):
    before = one(db, "SELECT count(*) FROM dw.fact_transaction")
    sh("etl.py", "--batch", "2", "--as-of", "2026-10-01")
    assert one(db, "SELECT count(*) FROM dw.fact_transaction") == before
    last = db.execute("SELECT rows_loaded, rows_read, rows_rejected FROM dw.etl_run ORDER BY run_id DESC LIMIT 1").fetchone()
    assert last[0] == 0 and last[1] == last[2]  # everything rejected as 'already loaded' or invalid


def test_reporting_view_matches_fact(db):
    assert one(db, "SELECT sum(txn_count) FROM dw.mv_monthly_branch_channel") == \
           one(db, "SELECT count(*) FROM dw.fact_transaction")


def test_account_lookup_uses_index(db):
    plan = "\n".join(r for r, in db.execute(
        "EXPLAIN SELECT * FROM dw.fact_transaction WHERE account_key = 42 AND txn_ts >= '2026-07-01'"))
    assert "ix_fact_account_ts" in plan
