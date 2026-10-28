"""Generate a synthetic core-banking extract (customers, accounts, transactions) as CSV files.

The data is fake but shaped like a real retail bank's daily extract, and it deliberately
contains the problems a production ETL has to catch:
  duplicate transaction IDs, missing amounts, negative amounts, unknown account IDs,
  future-dated transactions and invalid channel codes.

Run: python generate_data.py            -> data/batch1/*.csv  (initial load)
     python generate_data.py --batch 2  -> data/batch2/*.csv  (next day: new transactions,
                                                              some customers changed city/segment)
"""
import argparse
import csv
import random
from datetime import date, datetime, timedelta
from pathlib import Path

BRANCHES = [  # branch_code, branch_name, city, state
    ("JPR01", "Jaipur Main", "Jaipur", "Rajasthan"), ("JPR02", "Jaipur Malviya Nagar", "Jaipur", "Rajasthan"),
    ("BLR01", "Bengaluru Koramangala", "Bengaluru", "Karnataka"), ("BLR02", "Bengaluru Whitefield", "Bengaluru", "Karnataka"),
    ("MUM01", "Mumbai Andheri", "Mumbai", "Maharashtra"), ("DEL01", "Delhi Connaught Place", "Delhi", "Delhi"),
    ("CHN01", "Chennai T Nagar", "Chennai", "Tamil Nadu"), ("HYD01", "Hyderabad Madhapur", "Hyderabad", "Telangana"),
    ("PUN01", "Pune Baner", "Pune", "Maharashtra"), ("AHD01", "Ahmedabad SG Highway", "Ahmedabad", "Gujarat"),
]
CHANNELS = ["UPI", "NEFT", "IMPS", "RTGS", "ATM", "CARD", "BRANCH"]
SEGMENTS = ["Retail", "Salaried", "MSME", "Senior Citizen"]
ACCOUNT_TYPES = ["SAVINGS", "CURRENT", "SALARY"]
START = date(2026, 4, 1)
DAYS = 183  # Apr - Sep 2026


def main(batch: int, n_customers=5000, n_txn=200_000, seed=7):
    rng = random.Random(seed + batch)
    out = Path(f"data/batch{batch}")
    out.mkdir(parents=True, exist_ok=True)

    base = random.Random(seed)  # customers/accounts are the same population in every batch
    customers = []
    for i in range(1, n_customers + 1):
        b = base.choice(BRANCHES)
        customers.append({"customer_id": f"C{i:06d}", "full_name": f"Customer {i}", "segment": base.choice(SEGMENTS),
                          "city": b[2], "home_branch": b[0], "kyc_date": (START - timedelta(days=base.randint(30, 3000))).isoformat()})
    if batch == 2:  # 120 customers moved city or changed segment -> exercises SCD Type 2
        for c in rng.sample(customers, 120):
            b = rng.choice(BRANCHES)
            c["city"], c["home_branch"] = b[2], b[0]
            c["segment"] = rng.choice(SEGMENTS)

    accounts = []
    for i in range(1, int(n_customers * 1.6) + 1):
        c = base.choice(customers)
        accounts.append({"account_id": f"A{i:07d}", "customer_id": c["customer_id"], "account_type": base.choice(ACCOUNT_TYPES),
                         "branch_code": c["home_branch"], "opened_on": c["kyc_date"]})

    if batch == 1:
        days = range(DAYS)
    else:  # batch 2 = the next day only
        days = [DAYS]
    txns, seen = [], 0
    per_day = n_txn // len(days) if batch == 1 else 1500
    for d in days:
        day = START + timedelta(days=d)
        for _ in range(per_day):
            seen += 1
            a = rng.choice(accounts)
            ch = rng.choices(CHANNELS, weights=[45, 12, 15, 2, 10, 12, 4])[0]
            amt = round(rng.lognormvariate(7.2, 1.1), 2) if ch != "RTGS" else round(rng.uniform(200000, 1500000), 2)
            ts = datetime.combine(day, datetime.min.time()) + timedelta(seconds=rng.randint(0, 86399))
            txns.append({"txn_id": f"T{batch}{seen:08d}", "account_id": a["account_id"], "txn_ts": ts.isoformat(sep=" "),
                         "channel": ch, "direction": rng.choices(["DR", "CR"], weights=[60, 40])[0],
                         "amount": amt, "currency": "INR"})

    # --- plant data-quality problems (about 1% of rows)
    k = max(1, len(txns) // 500)
    for t in rng.sample(txns, k):
        t["amount"] = ""                                    # missing amount
    for t in rng.sample(txns, k):
        t["amount"] = -abs(float(t["amount"] or 1))         # negative amount
    for t in rng.sample(txns, k):
        t["account_id"] = f"A9{rng.randint(0, 999999):06d}"  # unknown account
    for t in rng.sample(txns, k):
        t["txn_ts"] = "2027-01-15 10:00:00"                 # future date
    for t in rng.sample(txns, k):
        t["channel"] = "FAX"                                # invalid channel
    txns += [dict(t) for t in rng.sample(txns, k)]          # duplicates

    for name, rows in [("branches", [dict(zip(["branch_code", "branch_name", "city", "state"], b)) for b in BRANCHES]),
                       ("customers", customers), ("accounts", accounts), ("transactions", txns)]:
        with open(out / f"{name}.csv", "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
    print(f"batch {batch}: {len(customers)} customers, {len(accounts)} accounts, {len(txns):,} transactions -> {out}/")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--batch", type=int, default=1)
    main(p.parse_args().batch)
