#!/bin/sh
# End-to-end tests: drive `polyquery session` / `exec` and compare responses.
# Each case: a request line and a substring the response must contain.
set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN="$DIR/bin/polyquery"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf 'id,name,amount\n1,a,1.50\n2,b,\n3,"c, d",-2.25\n' > "$TMP/t.csv"
pass=0
fail=0

check() { # request expected-substring
  out=$(printf '%s\n' "$1" | "$BIN" session --data-dir "$TMP" --enable-test-functions)
  case "$out" in
    *"$2"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  got:      $out" ;;
  esac
}

check_seq() { # file-of-requests expected-substring-of-last-line
  out=$("$BIN" session --data-dir "$TMP" --enable-test-functions < "$1" | tail -n 1)
  case "$out" in
    *"$2"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1)); echo "FAIL: sequence $1"; echo "  expected: $2"; echo "  got:      $out" ;;
  esac
}

LOAD='{"op":"load","table":"t","format":"csv","path":"t.csv","schema":[{"name":"id","type":"INT"},{"name":"name","type":"TEXT"},{"name":"amount","type":"DECIMAL(6,2)"}]}'
seq() { f="$TMP/seq.$$"; printf '%s\n' "$LOAD" "$@" > "$f"; echo "$f"; }

check '{"op":"version","id":7}' '"id":7,"ok":true'
check '{"op":"capabilities"}' '"sql.basic"'
check 'not json' '"code":"INVALID_REQUEST"'
check '{"op":"nope"}' '"code":"INVALID_REQUEST"'
check '{"op":"query","sql":"SELECT 1 + 2 * 3 AS x"}' '"rows":[[7]]'
check '{"op":"query","sql":"SELECT 7 / 2, -7 % 3"}' '"rows":[[3,-1]]'
check '{"op":"query","sql":"SELECT 0.1 + 0.2 AS s"}' '"rows":[["0.3"]]'
check '{"op":"query","sql":"SELECT CAST(2.345 AS DECIMAL(5,2))"}' '"rows":[["2.35"]]'
check '{"op":"query","sql":"SELECT DATE '"'"'2024-02-29'"'"', TIMESTAMP '"'"'2024-01-01 10:00:00.5'"'"'"}' '"2024-01-01 10:00:00.500000"'
check '{"op":"query","sql":"SELECT 1 / 0"}' '"code":"DIVISION_BY_ZERO"'
check '{"op":"query","sql":"SELECT 9223372036854775807 + 1"}' '"code":"NUMERIC_OVERFLOW"'
check '{"op":"query","sql":"SELECT 1 = '"'"'1'"'"'"}' '"code":"TYPE_ERROR"'
check '{"op":"query","sql":"SELECT 1 FROM missing"}' '"code":"SEMANTIC_ERROR"'
check '{"op":"query","sql":"SELEC 1"}' '"code":"PARSE_ERROR"'
check '{"op":"query","sql":"SELECT a FROM t FULL JOIN u ON a = b"}' '"code":"UNSUPPORTED"'
check '{"op":"query","sql":"SELECT 1 UNION SELECT 2"}' '"code":"UNSUPPORTED"'
check '{"op":"capabilities"}' '"change.union_all"'
check '{"op":"query","sql":"SELECT 1 AS a UNION ALL SELECT 2 UNION ALL SELECT 2 ORDER BY a DESC"}' '"rows":[[2],[2],[1]]'
check '{"op":"query","sql":"SELECT 1 AS v UNION ALL SELECT 2.50 UNION ALL SELECT NULL ORDER BY 1 LIMIT 2"}' '"columns":[{"name":"v","type":"DECIMAL(18,2)"}],"rows":[[null],["1.00"]]'
check '{"op":"query","sql":"SELECT 1 AS v UNION ALL SELECT 2.5E0"}' '"type":"FLOAT64"}],"rows":[[1],[2.5]]'
check '{"op":"query","sql":"WITH c AS (SELECT 1 AS x UNION ALL SELECT 2) SELECT SUM(x) FROM c"}' '"rows":[[3]]'
check '{"op":"query","sql":"SELECT * FROM (SELECT 1 AS x UNION ALL SELECT 2) d WHERE x > 1"}' '"rows":[[2]]'
check '{"op":"query","sql":"SELECT (SELECT 1 UNION ALL SELECT 2 ORDER BY 1 DESC LIMIT 1)"}' '"rows":[[2]]'
check '{"op":"query","sql":"SELECT 9223372036854775807 UNION ALL SELECT 0.5"}' '"code":"NUMERIC_OVERFLOW"'
check '{"op":"query","sql":"SELECT 1, 2 UNION ALL SELECT 3"}' '"code":"SEMANTIC_ERROR"'
check '{"op":"query","sql":"SELECT 1 UNION ALL SELECT '"'"'a'"'"'"}' '"code":"TYPE_ERROR"'
check '{"op":"query","sql":"SELECT 1 AS a UNION ALL SELECT 2 ORDER BY a + 1"}' '"code":"SEMANTIC_ERROR"'
check '{"op":"query","sql":"SELECT 1 LIMIT 1 UNION ALL SELECT 2"}' '"code":"PARSE_ERROR"'
check '{"op":"query","sql":"(SELECT 1) UNION ALL (SELECT 2)"}' '"code":"PARSE_ERROR"'
check '{"op":"query","sql":"SELECT 1 UNION DISTINCT SELECT 2"}' '"code":"UNSUPPORTED"'
check '{"op":"explain","sql":"SELECT 1 UNION ALL SELECT 2 LIMIT 1"}' '"op":"Limit","limit":1,"offset":0,"children":[{"op":"UnionAll","children":[{"op":"Project"'
check '{"op":"query","sql":"CREATE INDEX i ON t (c)"}' '"code":"SEMANTIC_ERROR"'
check '{"op":"query","sql":"SELECT 1\nFROM"}' '"details":{"line":2,"column":5}'
check '{"op":"query","sql":"WITH a AS (SELECT 1 AS v), b AS (SELECT v + 1 AS w FROM a) SELECT w FROM b"}' '"rows":[[2]]'
check '{"op":"query","sql":"WITH a AS (SELECT 1 AS v), a AS (SELECT 2 AS v) SELECT v FROM a"}' '"code":"SEMANTIC_ERROR"'
check '{"op":"query","sql":"SELECT d._col1, d.x FROM (SELECT 1 + 1, 2 AS x) d"}' '"rows":[[2,2]]'
check '{"op":"query","sql":"SELECT * FROM (SELECT 1 AS x) a CROSS JOIN (SELECT 2 AS y) b"}' '"rows":[[1,2]]'
check '{"op":"query","sql":"SELECT * FROM (SELECT 1 AS x) a JOIN (SELECT 1 AS x) b ON a.x = b.x"}' '"rows":[[1,1]]'
check '{"op":"query","sql":"SELECT x FROM (SELECT 1 AS x) a JOIN (SELECT 1 AS x) b ON a.x = b.x"}' '"code":"SEMANTIC_ERROR"'
check '{"op":"query","sql":"SELECT COUNT(*) FROM (SELECT 1 AS x) a LEFT JOIN (SELECT 2 AS y) b ON a.x = b.y"}' '"rows":[[1]]'
check '{"op":"explain","sql":"SELECT a.x FROM (SELECT 1 AS x) a JOIN (SELECT 1 AS y) b ON a.x = b.y"}' '"op":"HashJoin","join_type":"INNER"'
check '{"op":"query","sql":"EXPLAIN SELECT 1"}' '"columns":[{"name":"plan","type":"STRING"}]'
check '{"op":"query","sql":"SELECT PQ_SLEEP(5000)","options":{"timeout_ms":30}}' '"code":"TIMEOUT"'
check '{"op":"load","table":"x","format":"csv","path":"../etc/passwd"}' '"code":"ACCESS_DENIED"'
check '{"op":"load","table":"x","format":"jsonl","data":"{\"a\":1}\n{\"a\":2.5}\n"}' '"type":"FLOAT64"'
check_seq "$(seq '{"op":"query","sql":"SELECT name, amount FROM t ORDER BY amount DESC NULLS LAST"}')" '"rows":[["a","1.50"],["c, d","-2.25"],["b",null]]'
check_seq "$(seq '{"op":"query","sql":"SELECT SUM(amount), COUNT(*), AVG(id) FROM t"}')" '"rows":[["-0.75",3,2]]'
check_seq "$(seq '{"op":"query","sql":"SELECT id FROM t","options":{"max_rows":2}}')" '"code":"RESOURCE_LIMIT"'
check_seq "$(seq '{"op":"tables"}')" '"tables":[{"name":"t","row_count":3}]'
check_seq "$(seq '{"op":"query","sql":"SELECT name IS NULL AS k, COUNT(*), SUM(amount) FROM t GROUP BY k ORDER BY k"}')" '"rows":[[false,3,"-0.75"]]'
check_seq "$(seq '{"op":"query","sql":"SELECT amount IS NULL, COUNT(DISTINCT id) FROM t GROUP BY 1 HAVING COUNT(*) > 1"}')" '"rows":[[false,2]]'
check_seq "$(seq '{"op":"query","sql":"SELECT name, COUNT(*) FROM t GROUP BY id"}')" '"code":"SEMANTIC_ERROR"'
check_seq "$(seq '{"op":"query","sql":"SELECT DISTINCT amount IS NULL AS n FROM t ORDER BY n"}')" '"rows":[[false],[true]]'
check_seq "$(seq '{"op":"query","sql":"SELECT DISTINCT name FROM t ORDER BY id"}')" '"code":"SEMANTIC_ERROR"'
check_seq "$(seq '{"op":"query","sql":"SELECT a.id, b.id FROM t a JOIN t b ON a.id + 1 = b.id ORDER BY 1"}')" '"rows":[[1,2],[2,3]]'
check_seq "$(seq '{"op":"query","sql":"SELECT a.id, b.id FROM t a LEFT JOIN t b ON a.id < b.id AND b.id > 2 ORDER BY 1, 2"}')" '"rows":[[1,3],[2,3],[3,null]]'
check_seq "$(seq '{"op":"query","sql":"SELECT COUNT(*) FROM t a, t b, t c"}')" '"rows":[[27]]'
check_seq "$(seq '{"op":"query","sql":"SELECT COUNT(*) FROM t a, t b","options":{"max_rows":5}}')" '"rows":[[9]]'

# Phase 3: statistics, layouts, indexes, PQCF storage
check_seq "$(seq '{"op":"stats","table":"t"}')" '{"name":"amount","type":"DECIMAL(6,2)","null_count":1,"distinct_count":2,"min":"-2.25","max":"1.50"}'
check_seq "$(seq '{"op":"load","table":"r","format":"csv","path":"t.csv","options":{"layout":"row"}}' '{"op":"query","sql":"SELECT r.name, t.amount FROM r JOIN t ON r.id = t.id WHERE r.amount IS NULL"}')" '"rows":[["b",null]]'
check_seq "$(seq '{"op":"load","table":"d","format":"csv","path":"t.csv","options":{"dictionary":true}}' '{"op":"query","sql":"SELECT COUNT(DISTINCT name) FROM d WHERE name <> '"'"'a'"'"'"}')" '"rows":[[2]]'
check_seq "$(seq '{"op":"query","sql":"CREATE INDEX ti ON t (id) USING HASH"}' '{"op":"schema","table":"t"}')" '"indexes":[{"name":"ti","column":"id","kind":"HASH"}]'
check_seq "$(seq '{"op":"query","sql":"CREATE INDEX ti ON t (id)"}' '{"op":"explain","sql":"SELECT name FROM t WHERE id = 2"}')" '"op":"IndexScan","index":"ti","kind":"BTREE"'
check_seq "$(seq '{"op":"query","sql":"CREATE INDEX ti ON t (id)"}' '{"op":"query","sql":"SELECT name FROM t WHERE id BETWEEN 2 AND 9 ORDER BY id"}')" '"rows":[["b"],["c, d"]]'
check_seq "$(seq '{"op":"query","sql":"CREATE INDEX ti ON t (id)"}' '{"op":"query","sql":"DROP INDEX ti"}' '{"op":"query","sql":"DROP INDEX ti"}')" '"code":"NOT_FOUND"'
for enc in plain dict rle auto; do
  check_seq "$(seq '{"op":"save","table":"t","path":"t.pqcf","options":{"encoding":"'$enc'","row_group_size":2}}' '{"op":"open","table":"u","path":"t.pqcf","options":{"mmap":true}}' '{"op":"query","sql":"SELECT * FROM u ORDER BY id"}')" '"rows":[[1,"a","1.50"],[2,"b",null],[3,"c, d","-2.25"]]'
done
check_seq "$(seq '{"op":"save","table":"t","path":"t.pqcf","options":{"row_group_size":1}}' '{"op":"open","table":"u","path":"t.pqcf"}' '{"op":"explain","sql":"SELECT name FROM u WHERE id > 2"}')" '"row_groups_skipped":2'
# a damaged chunk: buffered open fails; a lazy (mmap) open fails on first access
printf '%s\n' "$LOAD" '{"op":"save","table":"t","path":"flip.pqcf","options":{"encoding":"plain"}}' > "$TMP/mk.jsonl"
"$BIN" session --data-dir "$TMP" < "$TMP/mk.jsonl" > /dev/null
printf '\377' | dd of="$TMP/flip.pqcf" bs=1 seek=9 conv=notrunc 2>/dev/null
check '{"op":"open","table":"f","path":"flip.pqcf"}' '"code":"STORAGE_CORRUPT"'
printf '%s\n' '{"op":"open","table":"f","path":"flip.pqcf","options":{"mmap":true}}' '{"op":"query","sql":"SELECT name FROM f"}' > "$TMP/lazy1.jsonl"
check_seq "$TMP/lazy1.jsonl" '"rows":[["a"],["b"],["c, d"]]'
printf '%s\n' '{"op":"open","table":"f","path":"flip.pqcf","options":{"mmap":true}}' '{"op":"query","sql":"SELECT id FROM f"}' > "$TMP/lazy2.jsonl"
check_seq "$TMP/lazy2.jsonl" '"code":"STORAGE_CORRUPT"'
printf 'PQCF\001\000\000\000garbage' > "$TMP/bad.pqcf"
check '{"op":"open","table":"b","path":"bad.pqcf"}' '"code":"STORAGE_CORRUPT"'
check '{"op":"open","table":"b","path":"none.pqcf"}' '"code":"NOT_FOUND"'
check_seq "$(seq '{"op":"save","table":"t","path":"nodir/t.pqcf"}')" '"code":"IO_ERROR"'

# exec mode with an array of requests
printf '[{"op":"query","sql":"SELECT 1 AS a"},{"op":"query","sql":"SELECT 2 AS b"}]' > "$TMP/req.json"
n=$("$BIN" exec --data-dir "$TMP" --request "$TMP/req.json" | grep -c '"ok":true')
if [ "$n" = 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: exec array ($n responses)"; fi

# usage errors exit with status 2
"$BIN" session --bogus </dev/null 2>/dev/null
if [ $? = 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: unknown option exit code"; fi

echo "session_test: $pass passed, $fail failed"
[ "$fail" = 0 ]
