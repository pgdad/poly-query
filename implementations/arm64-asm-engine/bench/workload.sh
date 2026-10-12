#!/usr/bin/env bash
# Workload benchmark: runs benchmarks/workloads/analytics.json through one
# `bin/polyquery session` and reports, per query, the median and best
# client-side wall-clock latency (request written -> response line read,
# includes result serialization) plus the engine's stats.elapsed_us.
#
#   bench/workload.sh DATA_DIR [RUNS] [OPTIONS_JSON]
# DATA_DIR holds the generated tables, e.g. /tmp/pq1m/1m from
#   python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pq1m --jobs 1
# OPTIONS_JSON (default {}) is merged into every query's options; queries
# marked "result":"count" in the workload always get that option.
# Requires python3 only to read the workload JSON (no engine code).
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
engine="$here/../bin/polyquery"
workload="$here/../../../benchmarks/workloads/analytics.json"
data=${1:?usage: workload.sh DATA_DIR [RUNS] [OPTIONS_JSON]}
runs=${2:-5}
extra=${3:-'{}'}

# one line per query: name<TAB>options-json<TAB>sql
mapfile -t qlines < <(python3 -I -c '
import json, sys
w = json.load(open(sys.argv[1])); extra = json.loads(sys.argv[2])
for q in w["queries"]:
    o = dict(extra)
    if q.get("result") == "count": o["result"] = "count"
    print(q["name"] + "\t" + json.dumps(o) + "\t" + q["sql"])
print("#idx")
for i in w["indexes"]: print(i["sql"])
' "$workload" "$extra")

coproc PQ { "$engine" session --data-dir "$data" 2>/dev/null; }
send() { printf '%s\n' "$1" >&"${PQ[1]}"; IFS= read -r resp <&"${PQ[0]}"; }

for t in transactions customers orders order_items products sensor_readings \
         sort_keys wide nulls_heavy; do
  send "{\"op\":\"load\",\"table\":\"$t\",\"path\":\"$t.csv\",\"format\":\"csv\",\"schema\":$(cat "$data/$t.schema.json")}"
  case $resp in *'"ok":true'*) ;; *) echo "load $t failed: $resp" >&2; exit 1;; esac
done
idx=0
for l in "${qlines[@]}"; do
  if [ "$l" = "#idx" ]; then idx=1; continue; fi
  [ $idx = 1 ] || continue
  send "{\"op\":\"query\",\"sql\":\"$l\"}"
  case $resp in *'"ok":true'*) ;; *) echo "index failed: $resp" >&2; exit 1;; esac
done

printf '%-28s %10s %10s %10s %8s\n' query wall_med wall_best engine_best rows
for l in "${qlines[@]}"; do
  [ "$l" = "#idx" ] && break
  IFS=$'\t' read -r name opts sql <<< "$l"
  walls=() engs=() rc=
  for ((i = 0; i < runs; i++)); do
    t0=${EPOCHREALTIME/./}
    send "{\"op\":\"query\",\"sql\":\"$sql\",\"options\":$opts}"
    t1=${EPOCHREALTIME/./}
    case $resp in *'"ok":true'*) ;; *) echo "$name failed: $resp" >&2; exit 1;; esac
    walls+=($((t1 - t0)))
    e=${resp##*\"elapsed_us\":}; engs+=("${e%%[!0-9]*}")
    r=${resp##*\"row_count\":}; rc=${r%%[!0-9]*}
  done
  med=$(printf '%s\n' "${walls[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
  best=$(printf '%s\n' "${walls[@]}" | sort -n | head -1)
  ebest=$(printf '%s\n' "${engs[@]}" | sort -n | head -1)
  awk -v n="$name" -v m="$med" -v b="$best" -v e="$ebest" -v r="$rc" \
    'BEGIN { printf "%-28s %8.1fms %8.1fms %8.1fms %8s\n", n, m/1000, b/1000, e/1000, r }'
done
exec {PQ[1]}>&-
wait
