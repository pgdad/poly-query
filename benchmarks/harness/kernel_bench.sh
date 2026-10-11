#!/usr/bin/env bash
# Independent kernel micro-benchmark of the committed assembly at a git ref.
# x86: built and run inside the sandbox, pinned to one core of the quiet host.
# arm: the same tree is benchmarked natively on the ARM host (tools/remote/arm_native.sh,
# pinned to one Cortex-X925 core). Run with no agents active for x86 numbers.
#
# Usage: kernel_bench.sh x86|arm <label> [git-ref]
# Output: results/performance/kernels-<arch>-<label>/{bench.jsonl, environment.json|arm-host.json,
#         codesize.json (.text bytes per assembly source), meta.json}
set -euo pipefail
cd "$(dirname "$0")/../.."
ARCH=$1; LABEL=$2; REF=${3:-HEAD}
BASE=${PQ_KBENCH_DIR:-/srv/polyquery/kbench}
W=$BASE/$LABEL-$ARCH
OUT=results/performance/kernels-$ARCH-$LABEL
SHA=$(git rev-parse "$REF")
git worktree remove --force "$W" 2>/dev/null || rm -rf "${W:?}"
mkdir -p "$BASE"
git worktree add -q --detach "$W" "$SHA"
mkdir -p "$OUT"
if [[ $ARCH == x86 ]]; then
  CPU=${PQ_KBENCH_CPU:-4}
  "$W/tools/orchestration/sandboxed.sh" bash -c "make -C native-kernels build/x86_64/kernel_bench >/dev/null && \
    taskset -c $CPU native-kernels/build/x86_64/kernel_bench 4194304 15" > "$OUT/bench.jsonl"
  python3 tools/environment/doctor.py --quiet --out "$OUT/environment.json" >/dev/null 2>&1 || true
  echo "{\"cpu\": $CPU, \"pinned\": true}" > "$OUT/pinning.json"
else
  tools/remote/arm_native.sh "$W/native-kernels" "$BASE/$LABEL-arm-out" --bench >/dev/null
  cp "$BASE/$LABEL-arm-out/bench.jsonl" "$BASE/$LABEL-arm-out/arm-host.json" "$OUT/"
  rm -rf "${BASE:?}/$LABEL-arm-out"
fi
# Code size of each assembly source (assembling only; nothing is executed).
if [[ $ARCH == x86 ]]; then DIR=x86_64 CC=gcc SIZE=size; else DIR=arm64 CC=aarch64-linux-gnu-gcc SIZE=aarch64-linux-gnu-size; fi
"$W/tools/orchestration/sandboxed.sh" bash -c "cd native-kernels && for f in $DIR/*.S; do \
  $CC -c -Iinclude -Ireference-c -o /tmp/k.o \$f && printf '%s %s\n' \$(basename \$f) \$($SIZE -A /tmp/k.o | awk '\$1==\".text\"{print \$2}'); done" \
  | python3 -c 'import json,sys; print(json.dumps({l.split()[0]: int(l.split()[1]) for l in sys.stdin if len(l.split()) == 2}, indent=1))' \
  > "$OUT/codesize.json"
printf '{"label": "%s", "arch": "%s", "ref": "%s", "measured": "%s"}\n' "$LABEL" "$ARCH" "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT/meta.json"
git worktree remove --force "$W"
echo "kernel_bench: $(grep -c '^{' "$OUT/bench.jsonl") rows -> $OUT"
