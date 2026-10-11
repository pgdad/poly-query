#!/bin/sh
# Phase 5 differential test: every query must produce byte-identical
# responses (results or error codes) under the row baseline, vectorized
# execution and parallel execution (forced onto tiny inputs with
# PQ_PAR_MIN=1), for every join algorithm.  The queries target the places
# where batch evaluation could diverge from tuple-at-a-time evaluation:
# short-circuit AND / OR / CASE and NULL operands guarding errors, overflow,
# mixed-scale decimals, dictionary strings, NULL group keys, DISTINCT
# aggregates, outer-join padding and subqueries.
set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN="$DIR/bin/polyquery"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# t: 3000 rows (several batches), u: 40 rows
awk 'BEGIN {
  print "a,b,n,d,f,s,dt,flag";
  for (i = 0; i < 3000; i++) {
    n = (i % 7 == 0) ? "" : i % 13;
    s = (i % 11 == 0) ? "" : "s" (i % 17);
    flag = (i % 5 == 0) ? "" : ((i % 2) ? "true" : "false");
    printf "%d,%d,%s,%d.%02d,%d.5,%s,2024-%02d-%02d,%s\n", i, i % 9 - 4, n, i % 500, i % 100, i % 50 - 25, s, i % 12 + 1, i % 28 + 1, flag
  } }' > "$TMP/t.csv"
awk 'BEGIN { print "k,name,w"; for (i = 0; i < 40; i++) printf "%d,u%d,%d.25\n", i % 30, i, i }' > "$TMP/u.csv"

QUERIES=$(cat <<'Q'
SELECT a, b FROM t WHERE b <> 0 AND a / b > 100
SELECT a FROM t WHERE b = 0 OR a / b > 300
SELECT a, CASE WHEN b <> 0 THEN a / b ELSE -1 END FROM t
SELECT a / b FROM t
SELECT a % b FROM t WHERE b <> 0
SELECT n + a / (b - b) FROM t WHERE n IS NULL
SELECT a * 4611686018427387904 FROM t
SELECT SUM(a * 3074457345618258602) FROM t
SELECT -a, a - 2 * a, f * 2, f / 0.5, d + 1, d * 2, d - f FROM t
SELECT a, d FROM t WHERE d > 250.5 AND d <= CAST(400 AS DECIMAL(10,3))
SELECT COUNT(*), SUM(d), AVG(d), MIN(d), MAX(d), SUM(f), MIN(s), MAX(s), COUNT(n), COUNT(flag) FROM t
SELECT b, COUNT(*), SUM(n), AVG(f), MIN(s), MAX(dt) FROM t GROUP BY b
SELECT n, COUNT(*) FROM t GROUP BY n
SELECT s, flag, COUNT(*), SUM(a) FROM t GROUP BY s, flag HAVING COUNT(*) > 5
SELECT b % 3, COUNT(DISTINCT n), SUM(DISTINCT b), COUNT(DISTINCT s) FROM t GROUP BY b % 3
SELECT COUNT(DISTINCT n), SUM(DISTINCT a % 10) FROM t
SELECT a, s FROM t WHERE s LIKE 's1%' AND n IN (1, 2, 3)
SELECT a FROM t WHERE flag AND NOT (n BETWEEN 3 AND 9)
SELECT a FROM t WHERE flag IS NULL OR n IS NOT NULL AND b > 2
SELECT a, s || '-' || CAST(n AS STRING), UPPER(s), LENGTH(s) FROM t WHERE a < 100
SELECT CAST(s AS INT) FROM t
SELECT CAST(d AS INT), CAST(a AS DECIMAL(6,1)), CAST(f AS STRING) FROM t WHERE a < 50
SELECT YEAR(dt), MONTH(dt), DATE_TRUNC('month', dt) FROM t WHERE a < 60
SELECT DISTINCT b, flag FROM t
SELECT a, d FROM t ORDER BY d DESC, a LIMIT 7
SELECT a, s FROM t ORDER BY s NULLS FIRST, a DESC LIMIT 5 OFFSET 20
SELECT a, n FROM t WHERE b > 0 ORDER BY n DESC NULLS LAST, a LIMIT 1500
SELECT a FROM t ORDER BY a LIMIT 0
SELECT a, a / b FROM t ORDER BY a LIMIT 3
SELECT a FROM t WHERE a > (SELECT AVG(a) FROM t) AND b IN (SELECT b FROM t WHERE b > 2)
SELECT t.a, u.name FROM t JOIN u ON u.k = t.b + 4 WHERE t.a < 40
SELECT t.a, u.name, u.w FROM t LEFT JOIN u ON u.k = t.a AND u.w > 3 WHERE t.a < 45
SELECT u.k, COUNT(*), SUM(t.d) FROM u JOIN t ON t.n = u.k GROUP BY u.k ORDER BY u.k
SELECT t.a, u.k FROM t JOIN u ON u.k < t.b WHERE t.a < 30
SELECT x.b, x.c FROM (SELECT b, COUNT(*) AS c FROM t GROUP BY b) x WHERE x.c > 300
SELECT a FROM t WHERE 1 = 0
SELECT COUNT(*), SUM(a), MIN(s) FROM t WHERE 1 = 0
SELECT b, COUNT(*) FROM t WHERE a < 0 GROUP BY b
SELECT a FROM t WHERE 1 / 0 = 1 AND a < 0
SELECT a FROM t WHERE a < 0 AND 1 / 0 = 1
SELECT 1 / 0 FROM t WHERE a < 0
SELECT CASE WHEN a < 0 THEN 1 / 0 ELSE 2 * 3 END FROM t WHERE a < 3
SELECT a FROM t WHERE a / b > 1 AND 1 = 0
SELECT a FROM t WHERE b > 3 AND 1 = 0
SELECT a FROM t WHERE (1 = 1 AND b = 2) OR 2 < 1
SELECT a, 10 * 10 + CAST('5' AS INT), UPPER('x') || s FROM t WHERE d > 100 + 0.5 AND TRUE
SELECT COUNT(*) FROM t WHERE n = 2 + 1 OR NULL
SELECT (a % b) * (a * 4611686018427387904) FROM t
SELECT b, MAX(a / (b + 4) + a * 3074457345618258602) FROM t GROUP BY b
SELECT a, s, n FROM t WHERE a < 300 ORDER BY s, n DESC LIMIT 25
SELECT b, s FROM t ORDER BY b LIMIT 30 OFFSET 400
Q
)

run() { # options -> responses (stats stripped)
  {
    printf '{"op":"load","table":"t","format":"csv","path":"t.csv","schema":[{"name":"a","type":"INT64"},{"name":"b","type":"INT64"},{"name":"n","type":"INT64"},{"name":"d","type":"DECIMAL(8,2)"},{"name":"f","type":"FLOAT64"},{"name":"s","type":"STRING"},{"name":"dt","type":"DATE"},{"name":"flag","type":"BOOLEAN"}]}\n'
    printf '{"op":"load","table":"u","format":"csv","path":"u.csv"}\n'
    echo "$QUERIES" | while IFS= read -r q; do
      printf '{"op":"query","sql":"%s","options":%s}\n' "$(printf '%s' "$q" | sed 's/"/\\"/g')" "$1"
    done
  } | PQ_PAR_MIN=1 "$BIN" session --data-dir "$TMP" | sed 's/,"stats":{[^}]*}//'
}

run '{"mode":"row","threads":1,"join":"nested_loop","optimize":false}' > "$TMP/base"
pass=0
fail=0
for opts in '{"mode":"row","threads":1}' \
            '{"mode":"vectorized","threads":1,"join":"merge"}' \
            '{"mode":"vectorized","threads":4,"join":"hash"}' \
            '{"mode":"row","threads":3,"join":"merge","optimize":false}' \
            '{"mode":"vectorized","threads":7,"join":"nested_loop"}'; do
  run "$opts" > "$TMP/out"
  i=0
  while IFS= read -r line; do
    i=$((i + 1))
    other=$(sed -n "${i}p" "$TMP/out")
    if [ "$line" = "$other" ]; then pass=$((pass + 1)); else
      fail=$((fail + 1))
      echo "FAIL ($opts) request $i"; echo "  base: $(printf '%s' "$line" | cut -c1-300)"; echo "  got:  $(printf '%s' "$other" | cut -c1-300)"
    fi
  done < "$TMP/base"
done
grep -n '"ok":false' "$TMP/base" | sed 's/"message".*//;s/^/modes_test: baseline error: request /'
echo "modes_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
