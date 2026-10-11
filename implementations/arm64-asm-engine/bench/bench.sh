#!/bin/sh
# Phase 5 benchmark: runs a fixed query set over generated data under
# several execution-option sets and prints the best of N runs (engine
# elapsed_us, ms) per query and option set.
#
#   bench/bench.sh DATA_DIR [RUNS]
# DATA_DIR holds transactions / customers / orders / order_items .csv
# (+ .schema.json) from
#   python3 datasets/generators/pqgen.py generate --scale 1m --out DIR
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
engine="$here/../bin/polyquery"
data=${1:?usage: bench.sh DATA_DIR [RUNS]}
runs=${2:-3}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

queries="
Q1|SELECT COUNT(*), SUM(amount) FROM tx WHERE status = 'approved' AND amount > 100
Q2|SELECT category, COUNT(*), SUM(amount), MIN(ts), MAX(fee) FROM tx GROUP BY category
Q3|SELECT bucket % 10 AS b, COUNT(*), SUM(amount), AVG(fee) FROM tx GROUP BY bucket % 10
Q4|SELECT tx_id, amount FROM tx WHERE status = 'approved' ORDER BY amount DESC, tx_id LIMIT 10
Q5|SELECT c.segment, COUNT(*), SUM(t.amount) FROM tx t JOIN cust c ON c.customer_id = t.customer_id GROUP BY c.segment
Q6|SELECT COUNT(*) FROM tx WHERE amount * 2 > 1000 AND bucket < 500 AND is_fraud = false
Q7|SELECT customer_id, COUNT(*) AS n FROM tx GROUP BY customer_id ORDER BY n DESC, customer_id LIMIT 5
Q8|SELECT COUNT(*), SUM(i.quantity) FROM items i JOIN orders o ON o.order_id = i.order_id JOIN cust c ON c.customer_id = o.customer_id WHERE c.segment = 'public_sector' AND c.birth_year < 1960
"
configs='
row-1|{"mode":"row","threads":1,"join":"hash"}
vec-1|{"mode":"vectorized","threads":1,"join":"hash"}
vec-4|{"mode":"vectorized","threads":4,"join":"hash"}
vec-8|{"mode":"vectorized","threads":8,"join":"hash"}
merge|{"mode":"vectorized","threads":1,"join":"merge"}
noopt|{"mode":"row","threads":1,"optimize":false}
vnoopt|{"mode":"vectorized","threads":1,"optimize":false}
'
req="$tmp/req.jsonl"
{
  printf '{"op":"load","table":"tx","path":"transactions.csv","format":"csv","schema":%s}\n' "$(cat "$data/transactions.schema.json")"
  printf '{"op":"load","table":"cust","path":"customers.csv","format":"csv","schema":%s}\n' "$(cat "$data/customers.schema.json")"
  printf '{"op":"load","table":"orders","path":"orders.csv","format":"csv","schema":%s}\n' "$(cat "$data/orders.schema.json")"
  printf '{"op":"load","table":"items","path":"order_items.csv","format":"csv","schema":%s}\n' "$(cat "$data/order_items.schema.json")"
  echo "$configs" | while IFS='|' read -r cname copts; do
    [ -n "$cname" ] || continue
    echo "$queries" | while IFS='|' read -r qname sql; do
      [ -n "$qname" ] || continue
      i=0
      while [ $i -lt "$runs" ]; do
        printf '{"id":"%s %s","op":"query","sql":"%s","options":%s}\n' "$cname" "$qname" "$sql" "$copts"
        i=$((i + 1))
      done
    done
  done
} > "$req"
"$engine" session --data-dir "$data" < "$req" > "$tmp/out.jsonl"
if grep -q '"ok":false' "$tmp/out.jsonl"; then
  grep '"ok":false' "$tmp/out.jsonl" >&2
  exit 1
fi
# best elapsed per (config, query)
sed -n 's/^{"id":"\([^ ]*\) \([^"]*\)".*"elapsed_us":\([0-9]*\).*/\1 \2 \3/p' "$tmp/out.jsonl" |
  sort -k1,1 -k2,2 -k3,3n | awk '
    { k = $1 " " $2; if (!(k in best)) { best[k] = $3; order[n++] = k } }
    END { for (i = 0; i < n; i++) { split(order[i], p, " ");
          printf "%-6s %-3s %9.1f ms\n", p[1], p[2], best[order[i]] / 1000 } }'
