#!/bin/sh
# Sort differential test (make test): ORDER BY queries whose results must
# come out in exactly the same order under mode "row" (qsort_r with the
# full comparator) and the vectorized radix sort (sort.S rsort_rows) with
# 1, 4 and 16 threads. PQ_PARALLEL_MIN_ROWS splits the 2000-row fixtures
# into many tasks. Covers STRING prefixes (inexact runs), DESC, NULLS
# FIRST / LAST, FLOAT64 (-0.0), DECIMAL incl. wide, DATE / TIMESTAMP /
# BOOLEAN keys, many keys (composite overflow), DISTINCT and LIMIT.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pq="$here/../../bin/polyquery"
data=${PQ_MODE_DATA:-"$here/../../../../tests/conformance/fixtures/gen"}
if [ ! -f "$data/sort_keys.csv" ]; then
    echo "sort tests: skipped (no fixtures at $data)"
    exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

load() {   # load NAME FILE
    printf '{"op":"load","table":"%s","path":"%s.csv","format":"csv","schema":%s}\n' \
        "$1" "$2" "$(cat "$data/$2.schema.json")"
}

cat > "$tmp/queries" <<'Q'
SELECT id, str_key FROM sk ORDER BY str_key, id
SELECT id, str_key FROM sk ORDER BY str_key DESC, id DESC
SELECT str_key, dup_key FROM sk ORDER BY str_key
SELECT str_key || 'abcdefghij' AS s, id FROM sk ORDER BY s DESC
SELECT SUBSTRING(str_key, 1, 1) AS c, id FROM sk ORDER BY c, id DESC
SELECT dup_key, float_key, id FROM sk ORDER BY dup_key DESC, float_key, id
SELECT -float_key AS nf, 0.0 * float_key AS z, id FROM sk ORDER BY z, nf
SELECT uniq_key, float_key FROM sk ORDER BY uniq_key % 2, float_key DESC
SELECT dup_key % 5 AS a, dup_key % 7 AS b, dup_key % 11 AS c, dup_key % 13 AS d, dup_key % 17 AS e, dup_key % 19 AS f, dup_key % 23 AS g, dup_key % 29 AS h, dup_key % 31 AS i, id FROM sk ORDER BY a, b, c, d, e, f, g, h, i
SELECT id, dup_key, uniq_key, str_key, float_key FROM sk ORDER BY uniq_key % 7, dup_key % 3 DESC, ROUND(float_key), str_key DESC, id % 11, uniq_key % 13, id % 17, dup_key % 19
SELECT id, n50, n90, s70 FROM nh ORDER BY n50, n90 DESC, id
SELECT id, s70, f95 FROM nh ORDER BY s70 NULLS LAST, f95 DESC NULLS FIRST, id
SELECT s70, b60, d99 FROM nh ORDER BY d99 DESC, b60, s70
SELECT s70, s70 || 'abcdefgh' AS t FROM nh ORDER BY t NULLS FIRST, s70 DESC
SELECT tx_id, amount, fee, ts FROM tx ORDER BY amount DESC, fee, ts
SELECT category, currency, amount FROM tx ORDER BY category, currency DESC
SELECT status, is_fraud, amount * 2 AS a2 FROM tx ORDER BY is_fraud DESC, status
SELECT CAST(amount AS DECIMAL(30,2)) AS w, tx_id FROM tx ORDER BY w DESC, tx_id
SELECT CAST(amount AS DECIMAL(30,2)) AS w, currency FROM tx ORDER BY currency, w
SELECT sensor_id, ts, temperature FROM sr ORDER BY temperature, ts DESC
SELECT status FROM sr ORDER BY status
SELECT NULL AS z, id FROM sk ORDER BY z, id DESC
SELECT id FROM sk ORDER BY id DESC LIMIT 1000 OFFSET 3
SELECT DISTINCT dup_key % 100 AS d, str_key FROM sk ORDER BY d DESC, str_key
Q

{
    load tx transactions
    load nh nulls_heavy
    load sr sensor_readings
    load sk sort_keys
} > "$tmp/load.jsonl"

n=0
for opts in \
    '{"mode":"row","threads":1}' \
    '{"mode":"vectorized","threads":1}' \
    '{"mode":"vectorized","threads":4}' \
    '{"mode":"vectorized","threads":16}'
do
    n=$((n + 1))
    {
        cat "$tmp/load.jsonl"
        while IFS= read -r q; do
            printf '{"op":"query","sql":"%s","options":%s}\n' "$q" "$opts"
        done < "$tmp/queries"
    } > "$tmp/req$n.jsonl"
    PQ_PARALLEL_MIN_ROWS=${PQ_PARALLEL_MIN_ROWS:-37} "$pq" session --data-dir "$data" < "$tmp/req$n.jsonl" |
        sed -e 's/,"stats":{[^}]*}//' > "$tmp/out$n"
done

fail=0
if grep -q '"ok":false' "$tmp/out1"; then
    echo "FAIL: a sort query failed"
    grep '"ok":false' "$tmp/out1" | head -3
    fail=1
fi
i=2
while [ $i -le $n ]; do
    if ! cmp -s "$tmp/out1" "$tmp/out$i"; then
        echo "FAIL: option set $i orders rows differently from mode row"
        diff "$tmp/out1" "$tmp/out$i" | cut -c1-300 | head -6
        fail=$((fail + 1))
    fi
    i=$((i + 1))
done
total=$(wc -l < "$tmp/queries")
echo "sort tests: $((n - 1))/$((n - 1)) option sets compared ($total queries, $fail failures)"
[ $fail -eq 0 ]
