#!/bin/sh
# Before/after timing of the AVX2 kernels: builds vbench from git revision
# $BASE (default: the pre-optimization baseline 424e5a4) and from the working
# tree, then runs both alternately, pinned to CPU $CPU, $ROUNDS times, and
# prints per-kernel medians. Usage: sh cmp.sh [kernel-substring]
# Env: BASE CPU ROUNDS N REPS VARIANT
set -e
D=$(cd "$(dirname "$0")/../.." && pwd)
O=$D/build/verify/cmp
BASE=${BASE:-424e5a4}; CPU=${CPU:-2}; ROUNDS=${ROUNDS:-5}; N=${N:-4194304}; REPS=${REPS:-15}
VARIANT=${VARIANT:-x86_avx2}
mkdir -p "$O/base/x86_64"
for f in $(cd "$D" && git ls-tree --name-only "$BASE" x86_64/ | grep -E '\.(S|h)$'); do
  (cd "$D" && git show "$BASE:native-kernels/$f" 2>/dev/null || git show "$BASE:$f") > "$O/base/$f"
done
CF="-O3 -w -I$D/include -I$D/reference-c"
REF="$D/reference-c/pq_kernels_ref.c $D/reference-c/pq_dispatch.c"
gcc $CF -o "$O/vb_base" "$D/x86_64/verify/vbench.c" $REF $O/base/x86_64/*.S -lm
gcc $CF -o "$O/vb_new" "$D/x86_64/verify/vbench.c" $REF $D/x86_64/*.S -lm
: > "$O/base.jsonl"; : > "$O/new.jsonl"
i=0
while [ $i -lt $ROUNDS ]; do
  taskset -c $CPU "$O/vb_base" $N $REPS $VARIANT "$1" >> "$O/base.jsonl"
  taskset -c $CPU "$O/vb_new" $N $REPS $VARIANT "$1" >> "$O/new.jsonl"
  i=$((i+1))
done
python3 -I - "$O/base.jsonl" "$O/new.jsonl" <<'PY'
import sys,json,statistics as st
def load(p):
  d={}
  for l in open(p):
    r=json.loads(l); d.setdefault(r['kernel'],[]).append(r['ns_per_elem'])
  return d
b,n=load(sys.argv[1]),load(sys.argv[2])
print('%-20s %8s %8s %7s   (min base/new)'%('kernel','base','new','speedup'))
for k in b:
  mb,mn=st.median(b[k]),st.median(n[k])
  print('%-20s %8.4f %8.4f %6.2fx   %.4f/%.4f'%(k,mb,mn,mb/mn,min(b[k]),min(n[k])))
PY
