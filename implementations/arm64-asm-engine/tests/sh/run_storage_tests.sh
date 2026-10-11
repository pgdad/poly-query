#!/bin/sh
# Phase 3 protocol tests that drive the engine binary (make test): layouts,
# dictionary encoding, statistics, indexes, index selection in EXPLAIN.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pq="$here/../../bin/polyquery"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
pass=0

check() {   # check NAME EXPECTED-SUBSTRING ACTUAL
    case "$3" in
        *"$2"*) pass=$((pass+1)) ;;
        *) echo "FAIL: $1"; echo "  expected substring: $2"; echo "  got: $3"; fail=$((fail+1)) ;;
    esac
}

# 40 rows: k = 1..40, g = k mod 4 (as text), v = k*10 or NULL every 5th row
{
    echo "k,g,v"
    i=1
    while [ $i -le 40 ]; do
        if [ $((i % 5)) -eq 0 ]; then v=""; else v=$((i * 10)); fi
        echo "$i,g$((i % 4)),$v"
        i=$((i + 1))
    done
} > "$tmp/t.csv"

run() {     # run REQUEST... -> responses
    printf '%s\n' \
      '{"op":"load","table":"c","format":"csv","path":"t.csv"}' \
      '{"op":"load","table":"r","format":"csv","path":"t.csv","options":{"layout":"row"}}' \
      '{"op":"load","table":"d","format":"csv","path":"t.csv","options":{"dictionary":true}}' \
      "$@" | "$pq" session --data-dir "$tmp"
}

q='SELECT g, COUNT(*) AS n, SUM(v) AS s FROM %s WHERE k > 3 GROUP BY g ORDER BY g'
expect='"rows":[["g0",10,1600],["g1",9,1590],["g2",9,1580],["g3",9,1570]]'
for t in c r d; do
    sql=$(printf "$q" $t)
    out=$(run "{\"op\":\"query\",\"sql\":\"$sql\"}" | tail -1)
    check "layout $t" "$expect" "$out"
done
out=$(run '{"op":"schema","table":"r"}' | tail -1)
check "schema layout" '"layout":"row"' "$out"
out=$(run '{"op":"load","table":"x","format":"csv","path":"t.csv","options":{"layout":"zigzag"}}' | tail -1)
check "bad layout" 'INVALID_REQUEST' "$out"

out=$(run '{"op":"stats","table":"r"}' | tail -1)
check "stats k" '{"name":"k","type":"INT64","null_count":0,"distinct_count":40,"min":1,"max":40}' "$out"
check "stats g" '{"name":"g","type":"STRING","null_count":0,"distinct_count":4,"min":"g0","max":"g3"}' "$out"
check "stats v" '{"name":"v","type":"INT64","null_count":8,"distinct_count":32,"min":10,"max":390}' "$out"

out=$(run '{"op":"query","sql":"CREATE INDEX ik ON c (k) USING HASH"}' \
          '{"op":"query","sql":"CREATE INDEX iv ON c (v)"}' \
          '{"op":"query","sql":"CREATE INDEX ik ON c (v)"}' \
          '{"op":"schema","table":"c"}' \
          '{"op":"query","sql":"SELECT k FROM c WHERE k IN (7, 3, 7, 99) ORDER BY k"}' \
          '{"op":"query","sql":"SELECT k FROM c WHERE v BETWEEN 100 AND 130"}' \
          '{"op":"query","sql":"SELECT COUNT(*) AS n FROM c WHERE v >= 0"}' \
          '{"op":"explain","sql":"SELECT k FROM c WHERE k = 5"}' \
          '{"op":"explain","sql":"SELECT k FROM c WHERE k = 5","options":{"use_indexes":false}}' \
          '{"op":"explain","sql":"SELECT k FROM c WHERE v > 0"}' \
          '{"op":"query","sql":"DROP INDEX ik"}' \
          '{"op":"query","sql":"DROP INDEX ik"}')
check "create duplicate index" 'ALREADY_EXISTS' "$out"
check "schema indexes" '"indexes":[{"name":"ik","column":"k","kind":"HASH"},{"name":"iv","column":"v","kind":"BTREE"}]' "$out"
check "hash IN lookup" '"rows":[[3],[7]]' "$out"
check "btree range lookup" '"rows":[[11],[12],[13]]' "$out"
check "nulls never indexed" '"rows":[[32]]' "$out"
check "explain index scan" '"op":"IndexScan","table":"c","alias":"c","columns":["k"],"filter":true,"index":"ik"' "$out"
check "explain no index" '{"op":"TableScan","table":"c","alias":"c","columns":["k"],"filter":true,"estimated_rows":1' "$out"
check "explain non-selective" '{"op":"TableScan","table":"c","alias":"c","columns":["k","v"]' "$out"
check "drop missing index" '"code":"NOT_FOUND"' "$out"

echo "storage tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
