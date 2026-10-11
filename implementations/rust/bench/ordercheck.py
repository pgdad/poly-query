#!/usr/bin/env python3
"""Ordered differential check of sorting on the large generated datasets.

Runs ORDER BY queries (full sorts and top-N over integer, FLOAT64, DECIMAL,
DATE, TIMESTAMP, BOOLEAN, plain and dictionary-encoded STRING keys, with
NULLs, directions and NULL placement) over the `pqgen.py --scale 1m` tables
in row mode and in vectorized configurations, and compares the result rows
**in order** (exact JSON).

Usage: ordercheck.py ENGINE DATA_DIR   (e.g. bin/polyquery /tmp/pqdata/1m)
"""
import hashlib
import json
import subprocess
import sys

engine, data = sys.argv[1], sys.argv[2]
tables = {"tx": "transactions", "sortk": "sort_keys", "nn": "nulls_heavy", "sensor": "sensor_readings"}
p = subprocess.Popen([engine, "session", "--data-dir", data], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True)


def call(r):
    p.stdin.write(json.dumps(r) + "\n")
    p.stdin.flush()
    return json.loads(p.stdout.readline())


for t, base in tables.items():
    schema = json.load(open(f"{data}/{base}.schema.json"))
    assert call({"op": "load", "table": t, "format": "csv", "path": f"{base}.csv", "schema": schema})["ok"]

qs = [
    "SELECT id, str_key FROM sortk ORDER BY str_key, id",
    "SELECT id, str_key FROM sortk ORDER BY str_key DESC",
    "SELECT id, str_key FROM sortk ORDER BY str_key",
    "SELECT dup_key, float_key, id FROM sortk ORDER BY dup_key DESC, float_key, id",
    "SELECT dup_key, float_key FROM sortk ORDER BY float_key DESC, dup_key",
    "SELECT id FROM sortk ORDER BY uniq_key DESC",
    "SELECT id, dup_key FROM sortk ORDER BY dup_key",
    "SELECT id, str_key, dup_key FROM sortk ORDER BY dup_key % 7, str_key DESC, uniq_key",
    "SELECT id, n50, s70 FROM nn ORDER BY n50, s70",
    "SELECT id, n50, s70 FROM nn ORDER BY n50 DESC NULLS LAST, s70 NULLS FIRST",
    "SELECT id, f95, b60 FROM nn ORDER BY b60 DESC, f95 NULLS FIRST",
    "SELECT id, d99 FROM nn ORDER BY d99 DESC",
    "SELECT id, n90, d99, s70 FROM nn ORDER BY s70 DESC NULLS LAST, d99, n90 DESC NULLS FIRST",
    "SELECT tx_id, category, amount FROM tx ORDER BY category, amount DESC",
    "SELECT tx_id, ts, status FROM tx ORDER BY status DESC, ts",
    "SELECT tx_id, fee FROM tx ORDER BY fee, tx_id DESC",
    "SELECT tx_id, is_fraud FROM tx ORDER BY is_fraud",
    "SELECT tx_id, currency, merchant_id FROM tx ORDER BY currency || 'x', merchant_id DESC",
    "SELECT tx_id FROM tx ORDER BY amount * 3, ts DESC, customer_id",
    "SELECT tx_id FROM tx ORDER BY CAST(amount AS DECIMAL(38, 4)) * 3, tx_id DESC",
    "SELECT sensor_id, temperature FROM sensor ORDER BY temperature DESC, sensor_id, ts",
    "SELECT sensor_id, ts FROM sensor ORDER BY sensor_id, ts DESC LIMIT 5000",
    "SELECT id, str_key FROM sortk ORDER BY str_key DESC, id LIMIT 3000",
    "SELECT id FROM sortk ORDER BY float_key, dup_key DESC LIMIT 100000",
    "SELECT id, n50 FROM nn ORDER BY n50 NULLS FIRST LIMIT 700000",
    "SELECT tx_id, status FROM tx WHERE tx_id < 50000 ORDER BY status, tx_id DESC",
    "SELECT tx_id, status FROM tx WHERE tx_id > 999990 ORDER BY status, ts",
    "SELECT n50 FROM nn WHERE id > 1000 AND id < 3000 ORDER BY 1",
    "SELECT n50 FROM nn WHERE n50 IS NULL ORDER BY 1",
]
variants = [{"mode": "vectorized", "threads": 1}, {"mode": "vectorized", "threads": 8}, {},
            {"optimize": False}]


def canon(r):
    if not r.get("ok"):
        return "error " + r["error"]["code"]
    return hashlib.sha256(json.dumps([r["columns"], r["rows"]]).encode()).hexdigest()


bad = 0
for q in qs:
    ref = canon(call({"op": "query", "sql": q, "options": {"mode": "row"}}))
    outs = [canon(call({"op": "query", "sql": q, "options": v})) for v in variants]
    ok = all(o == ref for o in outs)
    bad += not ok
    print("ok  " if ok else "DIFF", q, "" if ok else [ref] + outs, flush=True)
p.stdin.close()
p.wait()
print("differences:", bad)
sys.exit(1 if bad else 0)
