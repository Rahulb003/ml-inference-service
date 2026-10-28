"""Measure what the indexes buy: run two common queries with and without them.

  Q1 account statement: one account's transactions for a month (what support teams look up)
  Q2 branch report:     one branch's daily totals for a quarter
Run after etl.py:  python benchmark.py  -> writes benchmark.json
"""
import json
import os
import statistics
import time

import psycopg

DSN = os.environ.get("DATABASE_URL", "host=/var/tmp/pg port=5433 user=postgres dbname=postgres")
Q1 = """SELECT txn_ts, direction, amount FROM dw.fact_transaction
        WHERE account_key = 4242 AND txn_ts >= '2026-07-01' AND txn_ts < '2026-08-01' ORDER BY txn_ts"""
Q2 = """SELECT date_key, count(*), sum(amount) FROM dw.fact_transaction
        WHERE branch_key = 3 AND date_key BETWEEN 20260701 AND 20260930 GROUP BY date_key ORDER BY date_key"""
INDEXES = ["ix_fact_date", "ix_fact_account_ts", "ix_fact_branch_date"]


def median_ms(conn, sql, runs=30):
    times = []
    for _ in range(runs):
        t = time.perf_counter()
        conn.execute(sql).fetchall()
        times.append((time.perf_counter() - t) * 1000)
    return round(statistics.median(times), 2)


def main():
    with psycopg.connect(DSN, autocommit=True) as conn:
        conn.execute("ANALYZE dw.fact_transaction")
        rows = conn.execute("SELECT count(*) FROM dw.fact_transaction").fetchone()[0]
        with_idx = {"account_statement": median_ms(conn, Q1), "branch_report": median_ms(conn, Q2)}
        plan = conn.execute("EXPLAIN " + Q1).fetchone()[0]

        conn.execute("BEGIN")
        for ix in INDEXES:
            conn.execute(f"DROP INDEX dw.{ix}")
        without = {"account_statement": median_ms(conn, Q1), "branch_report": median_ms(conn, Q2)}
        conn.execute("ROLLBACK")  # indexes come back untouched

    out = {"fact_rows": rows, "with_indexes_ms": with_idx, "without_indexes_ms": without,
           "speedup_x": {k: round(without[k] / with_idx[k], 1) for k in with_idx}, "q1_plan": plan}
    with open("benchmark.json", "w") as f:
        json.dump(out, f, indent=2)
    print(f"fact rows: {rows:,}")
    for k in with_idx:
        print(f"{k:<18} without index {without[k]:>8} ms   with index {with_idx[k]:>6} ms   {out['speedup_x'][k]}x faster")
    print("Q1 plan:", plan)


if __name__ == "__main__":
    main()
