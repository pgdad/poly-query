#!/bin/sh
# bench.sh - Phase 5 measurements over the generated datasets.
#
#   python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata
#   sh implementations/x86_64-asm-engine/bench/bench.sh /tmp/pqdata/1m [REPS]
#
# Loads transactions + customers into one session, then runs every query
# under each option set REPS times (default 3) and prints the best
# server-side elapsed time (stats.elapsed_us) in milliseconds.
set -e
DIR=${1:?usage: bench.sh DATASET_DIR [REPS]}
REPS=${2:-3}
HERE=$(cd "$(dirname "$0")/.." && pwd)
ENGINE="$HERE/bin/polyquery"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

OPTSETS='{"mode":"row","threads":1,"optimize":false}
{"mode":"row","threads":1}
{"mode":"vectorized","threads":1}
{"mode":"vectorized","threads":4}
{"mode":"vectorized","threads":16}'

QUERIES='Q1 filter+count|SELECT COUNT(*) FROM tx WHERE amount > 100 AND merchant_id < 2500
Q2 scalar aggs|SELECT COUNT(*), SUM(amount), MIN(ts), MAX(fee), AVG(merchant_id) FROM tx
Q3 group by|SELECT category, status, COUNT(*), SUM(amount), AVG(fee) FROM tx GROUP BY category, status
Q4 group by expr|SELECT bucket % 10 AS b, COUNT(*), SUM(amount) FROM tx WHERE is_fraud = false GROUP BY bucket % 10
Q5 hash join+agg|SELECT c.segment, COUNT(*), SUM(t.amount) FROM tx t JOIN cust c ON c.customer_id = t.customer_id GROUP BY c.segment
Q6 top-N|SELECT tx_id, amount FROM tx WHERE status = '"'"'approved'"'"' ORDER BY amount DESC, tx_id LIMIT 10
Q7 projection|SELECT tx_id, amount * 2, fee + amount FROM tx WHERE merchant_id < 100
Q8 const fold|SELECT COUNT(*) FROM tx WHERE amount > 10 * 10 + 0 AND 1 = 1'

req() { printf '{"op":"query","sql":"%s","options":%s}\n' "$1" "$2"; }

{
  printf '{"op":"load","table":"tx","format":"csv","path":"transactions.csv","schema":%s}\n' "$(cat "$DIR/transactions.schema.json")"
  printf '{"op":"load","table":"cust","format":"csv","path":"customers.csv","schema":%s}\n' "$(cat "$DIR/customers.schema.json")"
  echo "$QUERIES" | while IFS='|' read -r name sql; do
    echo "$OPTSETS" | while read -r opts; do
      o=$(printf '%s' "$opts" | sed 's/}$/,"result":"count"}/')
      i=0; while [ $i -lt "$REPS" ]; do req "$sql" "$o"; i=$((i+1)); done
    done
  done
} > "$TMP/in.jsonl"

"$ENGINE" session --data-dir "$DIR" < "$TMP/in.jsonl" > "$TMP/out.jsonl"
if grep -q '"ok":false' "$TMP/out.jsonl"; then grep '"ok":false' "$TMP/out.jsonl" | head -3; exit 1; fi
tail -n +3 "$TMP/out.jsonl" | sed 's/.*"elapsed_us":\([0-9]*\).*/\1/' > "$TMP/us"

printf '%-18s' "query"
echo "$OPTSETS" | while read -r opts; do printf ' | %-12s' "$(printf '%s' "$opts" | sed 's/[{}"]//g;s/mode://;s/threads:/t=/;s/,optimize:false/,noopt/;s/vectorized/vec/')"; done
echo
n=0
echo "$QUERIES" | while IFS='|' read -r name sql; do
  printf '%-18s' "$name"
  k=0; nsets=$(echo "$OPTSETS" | wc -l)
  while [ $k -lt "$nsets" ]; do
    best=$(sed -n "$((n*nsets*REPS + k*REPS + 1)),$((n*nsets*REPS + k*REPS + REPS))p" "$TMP/us" | sort -n | head -1)
    printf ' | %9.1f ms' "$(echo "$best / 1000" | bc -l)"
    k=$((k+1))
  done
  echo
  n=$((n+1))
done
