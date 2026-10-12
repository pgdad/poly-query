#!/bin/sh
# CR-2 (DECIMAL precision 38) tests that drive the engine binary (make test):
# wide literals / arithmetic / comparisons / casts / aggregates, every
# layout, every execution option set, statistics, indexes and PQCF v2 round
# trips (PLAIN / RLE / small row groups, mmap).
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

# 30 rows: k = 1..30, w = (k mod 6 - 3) * 10^25 + k / 100 (DECIMAL(38,4)),
# n = k / 4 (DECIMAL(10,2)), i = k * 10^17 (INT64); NULL w every 7th row
{
    echo "k,w,n,i"
    i=1
    while [ $i -le 30 ]; do
        h=$((i % 6 - 3))
        if [ $((i % 7)) -eq 0 ]; then w=""; else
            if [ $h -lt 0 ]; then w="-$((-h))0000000000000000000000000.$(printf '%02d' $i)00"
            else w="${h}0000000000000000000000000.$(printf '%02d' $i)00"; fi
        fi
        echo "$i,$w,$((i / 4)).$((i % 4 * 25)),${i}00000000000000000"
        i=$((i + 1))
    done
} > "$tmp/w.csv"
schema='[{"name":"k","type":"INT64"},{"name":"w","type":"DECIMAL(38,4)"},{"name":"n","type":"DECIMAL(10,2)"},{"name":"i","type":"INT64"}]'

run() {     # run REQUEST... -> responses (tables c: column, r: row layout)
    printf '%s\n' \
      "{\"op\":\"load\",\"table\":\"c\",\"format\":\"csv\",\"path\":\"w.csv\",\"schema\":$schema}" \
      "{\"op\":\"load\",\"table\":\"r\",\"format\":\"csv\",\"path\":\"w.csv\",\"schema\":$schema,\"options\":{\"layout\":\"row\"}}" \
      "$@" | "$pq" session --data-dir "$tmp"
}
q1() {      # q1 SQL [OPTIONS] -> last response
    if [ -n "$2" ]; then run "{\"op\":\"query\",\"sql\":\"$1\",\"options\":$2}" | tail -1
    else run "{\"op\":\"query\",\"sql\":\"$1\"}" | tail -1; fi
}

# ---- scalar semantics
out=$(q1 'SELECT 12345678901234567890.5 * 2 AS a, -CAST(1 AS DECIMAL(38,37)) AS b, 9223372036854775807 < 9223372036854775807.5 AS c')
check "literal arithmetic" '"rows":[["24691357802469135781.0","-1.0000000000000000000000000000000000000",true]]' "$out"
check "literal types" '"type":"DECIMAL(38,1)"' "$out"
out=$(q1 "SELECT CAST('99999999999999999999999999999999999999' AS DECIMAL(38,0))")
check "38 digits fit" '"99999999999999999999999999999999999999"' "$out"
out=$(q1 'SELECT 99999999999999999999')
check "integer literal range" 'NUMERIC_OVERFLOW' "$out"
out=$(q1 'SELECT CAST(9.5e0 AS DECIMAL(20,0)) AS a, CAST(CAST(-2.5 AS DECIMAL(30,1)) AS DECIMAL(30,0)) AS b, ROUND(CAST(-2.55 AS DECIMAL(30,2)), 1) AS c, FLOOR(CAST(-0.1 AS DECIMAL(30,1))) AS d, CEIL(CAST(0.1 AS DECIMAL(30,1))) AS e')
check "rounding" '"rows":[["10","-3","-2.6","-1","1"]]' "$out"
out=$(q1 'SELECT CAST(CAST(123.456 AS DECIMAL(30,3)) AS FLOAT64) AS f, CAST(CAST(-123.9 AS DECIMAL(30,1)) AS INT64) AS i, CAST(CAST(1.5 AS DECIMAL(25,1)) AS STRING) AS s')
check "casts out" '"rows":[[123.456,-123,"1.5"]]' "$out"
out=$(q1 "SELECT CAST('99999999999999999999999999999999999999' AS DECIMAL(38,0)) + 1")
check "overflow" 'NUMERIC_OVERFLOW' "$out"
out=$(q1 'SELECT CAST(1 AS DECIMAL(30,20)) * CAST(1 AS DECIMAL(30,19))')
check "product scale" 'TYPE_ERROR' "$out"

# ---- the same answers in every layout and option set
q='SELECT k, w + n AS a, w * 2 AS b FROM %s WHERE w > 0 AND w < 20000000000000000000000000.1 ORDER BY w DESC, k'
expect='"rows":[[5,"20000000000000000000000001.3000","40000000000000000000000000.1000"],[22,"10000000000000000000000005.7200","20000000000000000000000000.4400"],[16,"10000000000000000000000004.1600","20000000000000000000000000.3200"],[10,"10000000000000000000000002.6000","20000000000000000000000000.2000"],[4,"10000000000000000000000001.0400","20000000000000000000000000.0800"],[27,"7.0200","0.5400"],[15,"3.9000","0.3000"],[9,"2.3400","0.1800"],[3,"0.7800","0.0600"]]'
for opt in '{"mode":"row"}' '{"mode":"vectorized"}' '{"mode":"vectorized","threads":4}' '{"optimize":false}'; do
    for t in c r; do
        sql=$(printf "$q" $t)
        check "filter $t $opt" "$expect" "$(q1 "$sql" "$opt")"
    done
done
q='SELECT a.k, b.k FROM c a JOIN r b ON FLOOR(a.w) = FLOOR(b.w) AND a.k < b.k WHERE a.k < 4 ORDER BY 1, 2'
for opt in '{"join":"hash"}' '{"join":"merge"}' '{"join":"nested_loop"}' '{"mode":"row"}'; do
    check "join $opt" '"rows":[[1,13],[1,19],[1,25],[2,8],[2,20],[2,26],[3,9],[3,15],[3,27]]' "$(q1 "$q" "$opt")"
done
q='SELECT COUNT(*) AS n FROM c a JOIN c b ON a.i = b.w'
check "int = wide join" '"rows":[[0]]' "$(q1 "$q")"
q='SELECT w > 0 AS p, COUNT(*) AS n, SUM(w) AS s, MIN(w) AS lo, MAX(n) AS hi FROM %s GROUP BY w > 0 ORDER BY 1'
expect='"rows":[[null,4,null,null,"7.00"],[false,13,"-270000000000000000000000002.0400","-30000000000000000000000000.3000","7.50"],[true,13,"140000000000000000000000001.9100","0.0300","7.25"]]'
for opt in '{"mode":"row"}' '{"mode":"vectorized","threads":4}'; do
    for t in c r; do
        sql=$(printf "$q" $t)
        check "grouping $t $opt" "$expect" "$(q1 "$sql" "$opt")"
    done
done
out=$(q1 'SELECT COUNT(DISTINCT w) AS d, AVG(w) AS a FROM c')
check "distinct / avg" '"rows":[[26,-5e+24]]' "$out"
out=$(q1 'SELECT k FROM c WHERE i > 2.5 AND i < 300000000000000000.5 ORDER BY k')
check "int vs decimal" '"rows":[[1],[2],[3]]' "$out"

# ---- statistics, indexes
out=$(run '{"op":"stats","table":"c"}' | tail -1)
check "stats w" '"min":"-30000000000000000000000000.3000","max":"20000000000000000000000000.2900"' "$out"
for kind in HASH BTREE; do
    out=$(run "{\"op\":\"query\",\"sql\":\"CREATE INDEX iw ON c (w) USING $kind\"}" \
              '{"op":"query","sql":"SELECT k FROM c WHERE w = 10000000000000000000000000.04 OR w = -20000000000000000000000000.2 ORDER BY k"}' | tail -1)
    check "index $kind" '"rows":[[4]]' "$out"
done

# ---- PQCF v2 round trips
for enc in plain rle auto; do
    out=$(run "{\"op\":\"save\",\"table\":\"c\",\"path\":\"w_$enc.pqcf\",\"options\":{\"encoding\":\"$enc\",\"row_group_size\":7}}" \
              "{\"op\":\"open\",\"table\":\"o\",\"path\":\"w_$enc.pqcf\",\"options\":{\"mmap\":true}}" \
              '{"op":"query","sql":"SELECT SUM(w) AS s, COUNT(w) AS n, MIN(w) AS lo FROM o WHERE w <> 0"}' | tail -1)
    check "pqcf $enc" '"rows":[["-130000000000000000000000000.1300",26,"-30000000000000000000000000.3000"]]' "$out"
    v=$(od -An -tu1 -j4 -N1 "$tmp/w_$enc.pqcf" | tr -d ' ')
    check "pqcf $enc version" "2" "$v"
done
out=$(run '{"op":"query","sql":"SELECT 1"}' \
          "{\"op\":\"load\",\"table\":\"nn\",\"format\":\"csv\",\"data\":\"a\\n1.5\\n\",\"schema\":[{\"name\":\"a\",\"type\":\"DECIMAL(18,1)\"}]}" \
          '{"op":"save","table":"nn","path":"nn.pqcf"}' | tail -1)
v=$(od -An -tu1 -j4 -N1 "$tmp/nn.pqcf" | tr -d ' ')
check "pqcf narrow version" "1" "$v"

echo "decimal38 tests: $pass passed, $fail failed"
[ $fail -eq 0 ]
