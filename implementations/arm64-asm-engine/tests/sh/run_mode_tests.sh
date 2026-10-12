#!/bin/sh
# Phase 5 differential test (make test): runs a query set under every
# combination of execution options (mode x join x threads x optimize) and
# checks that all of them return the same rows (compared as multisets) or
# the same error code. PQ_PARALLEL_MIN_ROWS makes the parallel code paths
# split even these small inputs into many tasks.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pq="$here/../../bin/polyquery"
data=${PQ_MODE_DATA:-"$here/../../../../tests/conformance/fixtures/gen"}
if [ ! -f "$data/transactions.csv" ]; then
    echo "mode tests: skipped (no fixtures at $data)"
    exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

load() {   # load NAME FILE
    printf '{"op":"load","table":"%s","path":"%s.csv","format":"csv","schema":%s}\n' \
        "$1" "$2" "$(cat "$data/$2.schema.json")"
}

cat > "$tmp/queries" <<'Q'
SELECT COUNT(*), SUM(amount), MIN(ts), MAX(category) FROM tx
SELECT category, COUNT(*), SUM(amount), AVG(fee), MIN(status), MAX(ts) FROM tx GROUP BY category
SELECT bucket % 7 AS b, is_fraud, COUNT(*) FROM tx WHERE amount > 100 GROUP BY bucket % 7, is_fraud HAVING COUNT(*) > 3
SELECT status, COUNT(DISTINCT category), COUNT(DISTINCT customer_id) FROM tx GROUP BY status
SELECT tx_id, amount FROM tx WHERE status = 'approved' AND amount * 2 > 300 ORDER BY amount DESC, tx_id LIMIT 7 OFFSET 3
SELECT tx_id FROM tx WHERE category < 'h' AND currency <> 'EUR' AND NOT is_fraud
SELECT c.segment, COUNT(*), SUM(t.amount) FROM tx t JOIN cust c ON c.customer_id = t.customer_id GROUP BY c.segment
SELECT c.country, t.status, COUNT(t.tx_id) FROM cust c LEFT JOIN tx t ON t.customer_id = c.customer_id AND t.amount > 500 GROUP BY c.country, t.status
SELECT o.order_id, i.line_no, p.name FROM orders o JOIN items i ON i.order_id = o.order_id JOIN products p ON p.product_id = i.product_id WHERE o.status = 'paid' AND i.quantity > 5
SELECT o.status, COUNT(i.order_id), SUM(i.quantity) FROM orders o LEFT JOIN items i ON i.order_id = o.order_id AND i.quantity > 8 GROUP BY o.status
SELECT a.id, b.id FROM nh a JOIN nh b ON a.n50 = b.n90 AND a.s70 = b.s70 WHERE a.id < b.id
SELECT a.id, b.id FROM nh a LEFT JOIN nh b ON a.n90 = b.n90 AND a.id <> b.id WHERE a.id < 300
SELECT n50 % 3, s70, COUNT(*), COUNT(n90), SUM(n90), MIN(d99), MAX(b60) FROM nh GROUP BY n50 % 3, s70
SELECT id, n50 + n90, COALESCE(s70, 'none'), f95 IS NULL, CASE WHEN b60 THEN 1 WHEN NOT b60 THEN 0 END FROM nh WHERE n50 IS NOT NULL OR b60
SELECT DISTINCT s70, b60 FROM nh
SELECT sensor_id, COUNT(*), ROUND(SUM(temperature), 6), MIN(humidity), MAX(pressure) FROM sr GROUP BY sensor_id
SELECT str_key, dup_key FROM sk WHERE dup_key BETWEEN 10 AND 90 AND str_key LIKE '%a%' ORDER BY str_key, dup_key, id LIMIT 20
SELECT dup_key, COUNT(*) FROM sk GROUP BY dup_key ORDER BY COUNT(*) DESC, dup_key LIMIT 5
SELECT customer_id FROM cust WHERE customer_id IN (SELECT customer_id FROM tx WHERE amount > 900)
SELECT c.customer_id, (SELECT COUNT(*) FROM tx t WHERE t.customer_id = c.customer_id) FROM cust c WHERE c.customer_id < 20
SELECT x.category, x.n FROM (SELECT category, COUNT(*) AS n FROM tx GROUP BY category) x WHERE x.n > 100
WITH big AS (SELECT * FROM tx WHERE amount > 800) SELECT b.status, COUNT(*) FROM big b JOIN cust c ON c.customer_id = b.customer_id GROUP BY b.status
SELECT t.tx_id, c.name FROM tx t, cust c WHERE t.customer_id = c.customer_id AND t.tx_id < 50 AND c.segment = 'consumer'
SELECT t.tx_id, c.customer_id FROM tx t JOIN cust c ON t.amount < c.credit_limit / 1000 WHERE t.tx_id < 30
SELECT 1 + 2 * 3, 'a' || 'b', CAST('2024-01-01' AS DATE) WHERE 1 = 1 AND TRUE
SELECT tx_id / (bucket - bucket) FROM tx
SELECT SUM(tx_id * 4611686018427387) FROM tx
SELECT COUNT(*) FROM tx WHERE 1 = 0
SELECT MAX(amount), MIN(amount), COUNT(*) FROM tx WHERE amount < 0
SELECT category, COUNT(*) FROM tx WHERE amount < 0 GROUP BY category
SELECT category, amount FROM tx WHERE amount > 900 UNION ALL SELECT segment, credit_limit FROM cust WHERE customer_id < 50 UNION ALL SELECT status, item_count FROM orders WHERE order_id < 40
SELECT k, COUNT(*), SUM(v) FROM (SELECT status AS k, fee AS v FROM tx UNION ALL SELECT segment, loyalty_points FROM cust UNION ALL SELECT s70, n90 FROM nh) u GROUP BY k
SELECT t.tx_id, u.x FROM tx t JOIN (SELECT customer_id AS c, 1 AS x FROM cust WHERE segment = 'consumer' UNION ALL SELECT customer_id, 2 FROM orders WHERE status = 'paid') u ON u.c = t.customer_id WHERE t.amount > 700
WITH a AS (SELECT customer_id FROM tx WHERE is_fraud UNION ALL SELECT customer_id FROM orders) SELECT c.customer_id FROM cust c WHERE c.customer_id IN (SELECT customer_id FROM a) AND c.customer_id < 300
SELECT c.customer_id, (SELECT COUNT(*) FROM (SELECT t.tx_id FROM tx t WHERE t.customer_id = c.customer_id UNION ALL SELECT o.order_id FROM orders o WHERE o.customer_id = c.customer_id) z) FROM cust c WHERE c.customer_id < 40
SELECT tx_id AS id FROM tx WHERE bucket = 3 UNION ALL SELECT customer_id FROM cust ORDER BY id DESC LIMIT 25 OFFSET 5
SELECT DISTINCT category FROM tx UNION ALL SELECT DISTINCT segment FROM cust UNION ALL SELECT NULL
Q

{
    load tx transactions
    load cust customers
    load orders orders
    load items order_items
    load products products
    load nh nulls_heavy
    load sr sensor_readings
    load sk sort_keys
} > "$tmp/load.jsonl"

n=0
for opts in \
    '{"mode":"row","join":"nested_loop","threads":1,"optimize":false}' \
    '{"mode":"row","join":"hash","threads":1}' \
    '{"mode":"row","join":"merge","threads":4}' \
    '{"mode":"vectorized","join":"hash","threads":4}' \
    '{"mode":"vectorized","join":"merge","threads":1,"optimize":false}' \
    '{"mode":"vectorized","join":"nested_loop","threads":4}' \
    '{"mode":"vectorized","join":"hash","threads":16,"optimize":false}' \
    '{}'
do
    n=$((n + 1))
    {
        cat "$tmp/load.jsonl"
        while IFS= read -r q; do
            printf '{"op":"query","sql":"%s","options":%s}\n' "$q" "$opts"
        done < "$tmp/queries"
    } > "$tmp/req$n.jsonl"
    PQ_PARALLEL_MIN_ROWS=${PQ_PARALLEL_MIN_ROWS:-37} "$pq" session --data-dir "$data" < "$tmp/req$n.jsonl" |
        sed -e 's/,"stats":{[^}]*}//' -e 's/"message":"[^"]*"//' > "$tmp/out$n"
    # rows as a multiset: one line per row, sorted within each response
    awk '{ i = index($0, "\"rows\":["); if (i == 0) { print; next }
           head = substr($0, 1, i + 7); rest = substr($0, i + 8);
           j = index(rest, "],\"row_count\""); body = substr(rest, 1, j - 1); tail = substr(rest, j);
           gsub(/\],\[/, "]\n[", body); m = split(body, r, "\n");
           for (k = 1; k <= m; k++) for (l = k + 1; l <= m; l++) if (r[l] < r[k]) { t = r[k]; r[k] = r[l]; r[l] = t }
           printf "%s", head; for (k = 1; k <= m; k++) printf "%s%s", (k > 1 ? "," : ""), r[k]; print tail }' \
        "$tmp/out$n" > "$tmp/norm$n"
done

fail=0
i=2
while [ $i -le $n ]; do
    if ! cmp -s "$tmp/norm1" "$tmp/norm$i"; then
        echo "FAIL: option set $i differs from option set 1"
        diff "$tmp/norm1" "$tmp/norm$i" | cut -c1-400 | head -6
        fail=$((fail + 1))
    fi
    i=$((i + 1))
done
errors=$(grep -c '"ok":false' "$tmp/norm1")
total=$(wc -l < "$tmp/queries")
echo "mode tests: $((n - 1 - fail))/$((n - 1)) option sets identical ($total queries, $errors expected errors)"
[ $fail -eq 0 ]
