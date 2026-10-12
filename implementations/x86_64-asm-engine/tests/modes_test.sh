#!/bin/sh
# Phase 5 differential test: every query must produce byte-identical
# responses (results or error codes) under the row baseline, vectorized
# execution and parallel execution (forced onto tiny inputs with
# PQ_PAR_MIN=1), for every join algorithm.  The queries target the places
# where batch evaluation could diverge from tuple-at-a-time evaluation:
# short-circuit AND / OR / CASE and NULL operands guarding errors, overflow,
# mixed-scale decimals, dictionary strings, NULL group keys, DISTINCT
# aggregates, outer-join padding, subqueries and UNION ALL compounds, and
# wide (boxed 128-bit) DECIMAL columns (table w, CR-2), full sorts on
# every key type (normalized-key sort) and hash-partitioned DISTINCT
# aggregates.  '{}' runs with the default (automatic) thread count.
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
# w: 3000 rows with wide decimals x DECIMAL(38,10), y DECIMAL(25,0) and a
# narrow z DECIMAL(10,2), NULLs in each
awk 'BEGIN {
  print "a,x,y,z";
  for (i = 0; i < 3000; i++) {
    if (i % 9 == 0) x = "";
    else if (i % 5 == 0) x = "1.5";
    else x = sprintf("%s%d%09d%09d.%05d%05d", (i % 4 == 0) ? "-" : "", i % 50, (i * 7919) % 1000000000, (i * 104729) % 1000000000, (i * 13) % 100000, (i * 17) % 100000);
    y = (i % 11 == 0) ? "" : sprintf("%s%d%010d%010d", (i % 3 == 0) ? "-" : "", i % 10, i % 97, i % 13);
    z = (i % 13 == 0) ? "" : sprintf("%d.%02d", i % 1000 - 500, i % 100);
    printf "%d,%s,%s,%s\n", i, x, y, z
  } }' > "$TMP/w.csv"

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
SELECT t.a, u.name FROM t JOIN u ON u.name = 'u' || CAST(t.b + 4 AS STRING) WHERE t.a < 60
SELECT u.name, COUNT(t.a) FROM u LEFT JOIN t ON t.s = 's' || CAST(u.k AS STRING) GROUP BY u.name ORDER BY u.name
SELECT t.a, u.w FROM t JOIN u ON u.w = t.d ORDER BY t.a
SELECT t.a, x.a FROM t JOIN t x ON x.f = t.f + 1 WHERE t.a < 20 ORDER BY t.a, x.a
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
SELECT a FROM t WHERE (100 > 100 AND b > 0) AND (a + 9223372036854775807) > 3
SELECT a FROM t WHERE (1 = 1 OR a / 0 > 1) AND (b > 3 OR 2 < 1)
SELECT b, MAX(a / (b + 4) + a * 3074457345618258602) FROM t GROUP BY b
SELECT a, s, n FROM t WHERE a < 300 ORDER BY s, n DESC LIMIT 25
SELECT b, s FROM t ORDER BY b LIMIT 30 OFFSET 400
SELECT a, d FROM t WHERE b > 2 UNION ALL SELECT k, w FROM u UNION ALL SELECT a, f FROM t WHERE a < 9
SELECT b AS g, COUNT(*) AS c FROM t GROUP BY b UNION ALL SELECT k, SUM(k) FROM u GROUP BY k ORDER BY c DESC, g LIMIT 12
SELECT s, n FROM t WHERE a < 500 UNION ALL SELECT name, NULL FROM u ORDER BY 2 NULLS FIRST, 1 LIMIT 40 OFFSET 3
SELECT COUNT(*), SUM(v) FROM (SELECT a AS v FROM t UNION ALL SELECT k FROM u UNION ALL SELECT NULL) x
SELECT t.a FROM t WHERE t.n IN (SELECT k FROM u WHERE w > 20 UNION ALL SELECT b FROM t WHERE b > 3) AND t.a < 300
SELECT a / b FROM t WHERE a < 10 UNION ALL SELECT a * 4611686018427387904 FROM t
SELECT a * 9223372036854 FROM t UNION ALL SELECT d FROM t
SELECT a, x + z, x * z, y - a, -x, ABS(x), x - y FROM w WHERE a < 60
SELECT a FROM w WHERE x > z AND y < 9223372036854775807
SELECT a FROM w WHERE x = 1.5 OR y IN (3, 70000000000, 100000000000000000000.) OR z = 7
SELECT a FROM w WHERE x BETWEEN -100 AND 1000000000000000000.5 OR y NOT BETWEEN -5 AND 50000000000000000000.
SELECT COUNT(*), SUM(x), AVG(x), MIN(x), MAX(x), SUM(y), AVG(y), COUNT(DISTINCT x), SUM(CAST(z AS DECIMAL(38,2))) FROM w
SELECT a % 7, SUM(x), MIN(y), MAX(y), AVG(x), COUNT(DISTINCT y), SUM(DISTINCT y) FROM w GROUP BY a % 7
SELECT x, COUNT(*) FROM w GROUP BY x ORDER BY x DESC LIMIT 20
SELECT y, z, COUNT(*), SUM(x) FROM w GROUP BY y, z HAVING COUNT(*) > 1 ORDER BY y, z
SELECT DISTINCT y FROM w ORDER BY y DESC NULLS FIRST LIMIT 30
SELECT a, x FROM w ORDER BY x, a LIMIT 50 OFFSET 100
SELECT w.a, v.a FROM w JOIN w v ON v.y = w.y WHERE w.a < 100 ORDER BY w.a, v.a
SELECT w.a, v.a FROM w LEFT JOIN w v ON v.x = w.x AND v.a > w.a WHERE w.a < 200
SELECT w.a, t.a FROM w JOIN t ON t.d = w.z WHERE w.a < 300
SELECT w.a, t.a FROM w JOIN t ON t.a = w.y WHERE w.a < 300
SELECT w.a, t.a FROM w JOIN t ON w.y = t.a + 70000000000 WHERE t.a < 300
SELECT t.a, u.name FROM t JOIN u ON t.d = u.k WHERE t.a < 2000
SELECT t.a, u.name FROM u LEFT JOIN t ON u.k = t.d AND t.a < 2000
SELECT w.a, t.a FROM w JOIN t ON t.d = w.x WHERE w.a < 300
SELECT a, x FROM w WHERE x > 0 AND a < 30 UNION ALL SELECT a, d FROM t WHERE a < 20
SELECT ROUND(x, 2), ROUND(x, -3), FLOOR(x), CEIL(x), CAST(x AS FLOAT64), CAST(y AS STRING), CAST(z AS DECIMAL(30,1)) FROM w WHERE a < 100
SELECT CAST(x AS INT) FROM w
SELECT SUM(y * y) FROM w
SELECT x * x FROM w
SELECT COALESCE(x, z, 0), CASE WHEN a > 5 THEN x ELSE z END, NULLIF(y, 70000000000), CASE y WHEN 70000000000 THEN 1 ELSE 0 END FROM w WHERE a < 40
SELECT a FROM w WHERE y IN (SELECT y FROM w WHERE a < 10) AND x NOT IN (SELECT x FROM w WHERE a < 20 AND x IS NOT NULL)
SELECT a FROM w WHERE x > (SELECT AVG(z) FROM w) AND a < 100
SELECT a FROM w WHERE y IN (SELECT x FROM w) OR z IN (SELECT y FROM w WHERE a < 50) OR a IN (SELECT y FROM w)
SELECT a FROM w WHERE x NOT IN (SELECT z FROM w WHERE z > 0) AND a < 400
SELECT a, s, f FROM t ORDER BY s DESC, f, a
SELECT a, n, flag FROM t ORDER BY flag NULLS FIRST, n DESC, dt, a
SELECT d, f, a FROM t ORDER BY f DESC, d, a
SELECT s, b FROM t ORDER BY s
SELECT dt, a FROM t ORDER BY dt DESC, a DESC
SELECT a FROM t ORDER BY f * 0, a DESC
SELECT a, s FROM t ORDER BY s || 'xxxxxxxxxxxxxxx' || CAST(a % 3 AS STRING), a
SELECT a, s FROM t ORDER BY s, a DESC
SELECT a, s FROM t ORDER BY s || 'xxxxxxxxxx' DESC, a
SELECT a, x, y FROM w ORDER BY y DESC NULLS LAST, x, a
SELECT a, z FROM w ORDER BY z NULLS FIRST, a DESC
SELECT b, COUNT(*) AS c FROM t GROUP BY b ORDER BY c DESC, b
SELECT COUNT(DISTINCT s), MIN(DISTINCT s), MAX(DISTINCT dt), AVG(DISTINCT d), SUM(DISTINCT n), COUNT(*), SUM(f) FROM t
SELECT COUNT(DISTINCT f), SUM(DISTINCT f), MAX(DISTINCT flag) FROM t
SELECT COUNT(DISTINCT 100 / (b + 4)) FROM t
SELECT SUM(DISTINCT x), AVG(DISTINCT y), MAX(DISTINCT x), COUNT(DISTINCT z) FROM w
Q
)

run() { # options -> responses (stats stripped)
  {
    printf '{"op":"load","table":"t","format":"csv","path":"t.csv","schema":[{"name":"a","type":"INT64"},{"name":"b","type":"INT64"},{"name":"n","type":"INT64"},{"name":"d","type":"DECIMAL(8,2)"},{"name":"f","type":"FLOAT64"},{"name":"s","type":"STRING"},{"name":"dt","type":"DATE"},{"name":"flag","type":"BOOLEAN"}]}\n'
    printf '{"op":"load","table":"u","format":"csv","path":"u.csv"}\n'
    printf '{"op":"load","table":"w","format":"csv","path":"w.csv","schema":[{"name":"a","type":"INT64"},{"name":"x","type":"DECIMAL(38,10)"},{"name":"y","type":"DECIMAL(25,0)"},{"name":"z","type":"DECIMAL(10,2)"}]}\n'
    echo "$QUERIES" | while IFS= read -r q; do
      printf '{"op":"query","sql":"%s","options":%s}\n' "$(printf '%s' "$q" | sed 's/"/\\"/g')" "$1"
    done
  } | PQ_PAR_MIN=1 "$BIN" session --data-dir "$TMP" | sed 's/,"stats":{[^}]*}//'
}

run '{"mode":"row","threads":1,"join":"nested_loop","optimize":false}' > "$TMP/base"
pass=0
fail=0
for opts in '{"mode":"row","threads":1}' \
            '{}' \
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
grep -n '"ok":false' "$TMP/base" | sed 's/"message".*//;s/^/modes_test: (expected) error case, request /'
echo "modes_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
