#!/usr/bin/env python3
"""Differential check on the large generated datasets.

Runs analytic queries over the `pqgen.py --scale 1m` tables (plus a
memory-mapped PQCF copy with many row groups) in row mode and in several
vectorized / parallel / join configurations, and compares the results
(multisets; FLOAT64 to 9 significant digits) and error codes.

Usage: bigdiff.py ENGINE DATA_DIR   (e.g. bin/polyquery /tmp/pqdata/1m)
"""
import json
import subprocess
import sys

engine, data = sys.argv[1], sys.argv[2]
names = {"tx":"transactions","cust":"customers","orders":"orders","items":"order_items","products":"products","sortk":"sort_keys","nulls":"nulls_heavy"}
p = subprocess.Popen([engine, "session", "--data-dir", data], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
def call(r):
    p.stdin.write(json.dumps(r)+"\n"); p.stdin.flush(); return json.loads(p.stdout.readline())
for t in names:
    schema = json.load(open(f"{data}/{names[t]}.schema.json"))
    tn = "nn" if t == "nulls" else t
    assert call({"op":"load","table":tn,"format":"csv","path":f"{names[t]}.csv","schema":schema})["ok"]
assert call({"op": "save", "table": "tx", "path": "tx_big.pqcf"}).get("ok")
r = call({"op":"open","table":"txp","path":"tx_big.pqcf","options":{"mmap":True}})
print("pqcf open:", r.get("ok"), r.get("error"))
qs = [
 "SELECT category, COUNT(*), SUM(amount), AVG(fee), MIN(ts), MAX(amount), MIN(currency), MAX(status) FROM tx GROUP BY category",
 "SELECT customer_id, COUNT(*), SUM(amount), MAX(category) FROM tx GROUP BY customer_id",
 "SELECT tx_id % 500000, COUNT(*), MAX(ts), MIN(category) FROM tx GROUP BY 1",
 "SELECT customer_id, category, COUNT(*) FROM tx GROUP BY 1, 2",
 "SELECT DISTINCT customer_id, category FROM tx",
 "SELECT DISTINCT merchant_id FROM txp",
 "SELECT c.segment, COUNT(*), SUM(t.amount) FROM tx t JOIN cust c ON c.customer_id = t.customer_id GROUP BY c.segment",
 "SELECT o.status, SUM(i.quantity * i.unit_price), COUNT(*) FROM orders o JOIN items i ON i.order_id = o.order_id GROUP BY o.status",
 "SELECT o.status, COUNT(i.order_id) FROM orders o LEFT JOIN items i ON i.order_id = o.order_id AND i.quantity > 8 GROUP BY o.status",
 "SELECT p.category, SUM(i.quantity) FROM items i JOIN orders o ON o.order_id = i.order_id JOIN products p ON p.product_id = i.product_id WHERE o.status = 'delivered' GROUP BY p.category",
 "SELECT tx_id, amount FROM txp WHERE status = 'approved' ORDER BY amount DESC, tx_id LIMIT 50",
 "SELECT id, uniq_key FROM sortk ORDER BY uniq_key LIMIT 2000",
 "SELECT str_key, id FROM sortk ORDER BY str_key DESC, id LIMIT 3000",
 "SELECT float_key, id FROM sortk ORDER BY float_key, id LIMIT 1000",
 "SELECT dup_key, COUNT(*), MIN(str_key), MAX(float_key) FROM sortk GROUP BY dup_key",
 "SELECT COUNT(*), COUNT(n50), SUM(n90), COUNT(DISTINCT s70), MAX(d99), AVG(f95) FROM nn",
 "SELECT b60, COUNT(*), SUM(n50) FROM nn GROUP BY b60",
 "SELECT YEAR(ts), MONTH(ts), COUNT(*), SUM(fee) FROM txp GROUP BY 1, 2",
 "SELECT COUNT(*) FROM tx t WHERE t.amount > (SELECT AVG(amount) FROM tx)",
 "SELECT category, COUNT(*) FROM tx WHERE customer_id IN (SELECT customer_id FROM cust WHERE segment = 'enterprise') GROUP BY category",
 "SELECT SUM(tx_id * 4611686018427387) FROM tx",
 "SELECT tx_id / (bucket - bucket) FROM tx",
 "SELECT UPPER(category) || '-' || LOWER(status), COUNT(*) FROM txp GROUP BY 1",
 "SELECT CAST(amount AS DOUBLE) * 2, COUNT(*) FROM tx WHERE amount BETWEEN 100 AND 101 GROUP BY 1",
]
variants = [{"mode":"row","threads":1}, {"mode":"vectorized","threads":1}, {"mode":"vectorized","threads":8}, {}, {"mode":"vectorized","threads":8,"join":"merge"}]
def canon(r):
    if not r.get("ok"): return ("error", r["error"]["code"])
    rows = [[("f%.9e" % v) if isinstance(v, float) else v for v in row] for row in r["rows"]]
    return ("ok", r["columns"], sorted(json.dumps(x) for x in rows))
bad = 0
for q in qs:
    outs = [canon(call({"op":"query","sql":q,"options":v})) for v in variants]
    same = all(o == outs[0] for o in outs)
    if not same:
        bad += 1
        print("DIFF", q)
        for v, o in zip(variants, outs): print("   ", v, str(o)[:200])
    else:
        print("ok", q[:90], "|", outs[0][0], len(outs[0][2]) if outs[0][0]=="ok" else outs[0][1])
print("differences:", bad)
sys.exit(1 if bad else 0)
