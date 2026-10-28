"""Run the ETL: extract CSVs -> staging (COPY) -> stored procedures -> star schema -> reconciliation.

Usage:
  python etl.py --init                         # create schemas, tables, procedures, indexes
  python etl.py --batch 1 --as-of 2026-09-30   # initial load (6 months of transactions)
  python etl.py --batch 2 --as-of 2026-10-01   # next-day incremental load (SCD2 changes)

Connection: set DATABASE_URL, e.g. postgresql://postgres@localhost:5432/postgres
"""
import argparse
import os
import time
from pathlib import Path

import psycopg

DSN = os.environ.get("DATABASE_URL", "host=/var/tmp/pg port=5433 user=postgres dbname=postgres")
TABLES = ["branches", "customers", "accounts", "transactions"]


def run_sql_file(conn, path):
    with conn.cursor() as cur:
        cur.execute(Path(path).read_text())


def init(conn):
    for f in ["schema.sql", "procedures.sql", "indexes.sql"]:
        run_sql_file(conn, f)
    print("schemas, tables, procedures and indexes created")


def extract_to_staging(conn, batch: int):
    folder = Path(f"data/batch{batch}")
    with conn.cursor() as cur:
        for t in TABLES:
            cur.execute(f"TRUNCATE stg.{t}")
            with open(folder / f"{t}.csv") as f, cur.copy(f"COPY stg.{t} FROM STDIN WITH (FORMAT csv, HEADER true, NULL '')") as cp:
                while chunk := f.read(1 << 20):
                    cp.write(chunk)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--init", action="store_true")
    p.add_argument("--batch", type=int)
    p.add_argument("--as-of")
    a = p.parse_args()
    with psycopg.connect(DSN, autocommit=True) as conn:
        conn.add_notice_handler(lambda n: print("  db:", n.message_primary))
        if a.init:
            init(conn)
        if a.batch:
            t0 = time.perf_counter()
            extract_to_staging(conn, a.batch)
            conn.execute("CALL dw.sp_run_etl(%s, %s)", (f"batch{a.batch}", a.as_of))
            run = conn.execute("SELECT run_id, status, rows_read, rows_loaded, rows_rejected, error_message "
                               "FROM dw.etl_run ORDER BY run_id DESC LIMIT 1").fetchone()
            print(f"run {run[0]}: {run[1]} in {time.perf_counter() - t0:.1f}s | read {run[2]:,} | "
                  f"loaded {run[3]:,} | rejected {run[4]:,}" + (f" | {run[5]}" if run[5] else ""))
            for reason, n in conn.execute("SELECT reason, count(*) FROM dw.etl_reject WHERE run_id = %s "
                                          "GROUP BY 1 ORDER BY 2 DESC", (run[0],)):
                print(f"  rejected: {reason:<28} {n:>5}")
            for name, exp, act, ok in conn.execute("SELECT * FROM dw.fn_reconcile(%s)", (run[0],)):
                print(f"  reconcile: {name:<42} expected {exp:>7,} actual {act:>7,} {'OK' if ok and exp == act else 'MISMATCH'}")


if __name__ == "__main__":
    main()
