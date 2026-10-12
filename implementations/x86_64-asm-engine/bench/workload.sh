#!/bin/sh
# workload.sh - latency of benchmarks/workloads/analytics.json through
# `bin/polyquery session`.
#
#   python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata
#   sh implementations/x86_64-asm-engine/bench/workload.sh /tmp/pqdata/1m [REPS] [OPTIONS]
#
# Loads every workload table (explicit schemas), creates the workload
# indexes, runs each query once as a warm-up and then REPS times (default 5)
# with OPTIONS (default {} = the engine defaults) and prints per query the
# median and best server-side elapsed time (stats.elapsed_us) in ms.
# The result rows of the warm-up runs are written to $PQ_BENCH_OUT (if set)
# so two engine versions can be compared for identical results.
set -e
DIR=${1:?usage: workload.sh DATASET_DIR [REPS] [OPTIONS]}
REPS=${2:-5}
OPTS=${3:-'{}'}
HERE=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WL="$ROOT/benchmarks/workloads/analytics.json"
ENGINE="${PQ_ENGINE:-$HERE/bin/polyquery}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# one "name<TAB>result<TAB>sql" line per query (the workload file keeps each
# query on one line)
grep '"name": "q' "$WL" | sed 's/.*"name": "\([^"]*\)".*/\1/' > "$TMP/names"
grep '"sql": "SELECT\|"sql": "WITH' "$WL" | sed 's/.*"sql": "\(.*\)"}.*/\1/' > "$TMP/sqls"
grep '"name": "q' "$WL" | sed 's/.*"result": "count".*/count/;t;s/.*/rows/' > "$TMP/kinds"
NQ=$(wc -l < "$TMP/names")

{
  for t in transactions customers orders order_items products sensor_readings sort_keys wide nulls_heavy; do
    printf '{"op":"load","table":"%s","format":"csv","path":"%s.csv","schema":%s}\n' \
      "$t" "$t" "$(cat "$DIR/$t.schema.json")"
  done
  grep '"sql": "CREATE INDEX' "$WL" | sed 's/.*"sql": "\([^"]*\)".*/{"op":"query","sql":"\1"}/'
  i=1
  while [ $i -le "$NQ" ]; do
    sql=$(sed -n "${i}p" "$TMP/sqls")
    kind=$(sed -n "${i}p" "$TMP/kinds")
    o=$(printf '%s' "$OPTS" | sed "s/}\$/,\"result\":\"$kind\"}/;s/{,/{/")
    printf '{"op":"query","sql":"%s","options":%s}\n' "$sql" "$o"
    o=$(printf '%s' "$OPTS" | sed 's/}$/,"result":"count"}/;s/{,/{/')
    r=0; while [ $r -lt "$REPS" ]; do
      printf '{"op":"query","sql":"%s","options":%s}\n' "$sql" "$o"; r=$((r+1))
    done
    i=$((i+1))
  done
} > "$TMP/in.jsonl"

NPRE=$(( 9 + $(grep -c '"sql": "CREATE INDEX' "$WL") ))
"$ENGINE" session --data-dir "$DIR" < "$TMP/in.jsonl" > "$TMP/out.jsonl"
if grep -q '"ok":false' "$TMP/out.jsonl"; then grep '"ok":false' "$TMP/out.jsonl" | head -3; exit 1; fi
tail -n +$((NPRE + 1)) "$TMP/out.jsonl" > "$TMP/q.jsonl"
if [ -n "$PQ_BENCH_OUT" ]; then
  awk -v n=$((REPS + 1)) 'NR % n == 1' "$TMP/q.jsonl" | sed 's/,"stats":{[^}]*}//' > "$PQ_BENCH_OUT"
fi
sed 's/.*"elapsed_us":\([0-9]*\).*/\1/' "$TMP/q.jsonl" > "$TMP/us"

printf '%-28s %10s %10s\n' query "median ms" "best ms"
i=1
while [ $i -le "$NQ" ]; do
  first=$(( (i - 1) * (REPS + 1) + 2 ))
  sed -n "${first},$((first + REPS - 1))p" "$TMP/us" | sort -n > "$TMP/s"
  med=$(sed -n "$(( (REPS + 1) / 2 ))p" "$TMP/s")
  best=$(head -1 "$TMP/s")
  printf '%-28s %10.1f %10.1f\n' "$(sed -n "${i}p" "$TMP/names")" \
    "$(echo "$med / 1000" | bc -l)" "$(echo "$best / 1000" | bc -l)"
  i=$((i+1))
done
