#!/usr/bin/env bash
# Independent before/after benchmark for the optimize-latency family.
#
# For each given run: "before" = the engine directory at the commit the run started
# from (manifest repo_ref); "after" = the engine directory on the run's import branch
# (the agent's commits on top of repo_ref, whether merged or not — timed-out runs are
# measured too and labelled by their outcome in the run record). Both sides live in
# separate worktrees, are built inside the sandbox and benchmarked back-to-back with
# the same harness and deterministically regenerated datasets. Run with no agents active.
#
# Usage: before_after.sh <scale> <run_id>...   (one run per language)
# PQ_BA_TASK names the task in the labels (default optimize -> "<side>-optimize");
# PQ_BA_TRACK is passed to bench.py (default A; Track B runs are reported only in Track B).
set -euo pipefail
cd "$(dirname "$0")/../.."
SCALE=$1; shift
TASK=${PQ_BA_TASK:-optimize}
TRACK=${PQ_BA_TRACK:-A}
BASE=${PQ_BEFORE_AFTER_DIR:-/srv/polyquery/before-after}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
langs=()
for side in before after; do
  git worktree remove --force "$BASE/$side" 2>/dev/null || rm -rf "${BASE:?}/$side"
  git worktree add -q --detach "$BASE/$side" HEAD
done
for run in "$@"; do
  read -r lang before after < <(python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))
print(m["language"], m["repo_ref"], m["import_branch"])' "/srv/polyquery/runs/$run/manifest.json")
  git -C "$BASE/before" checkout -q "$before" -- "implementations/$lang"
  git -C "$BASE/after" checkout -q "$after" -- "implementations/$lang"
  langs+=("$lang")
  echo "before_after: $lang before=${before:0:12} after=$after ($run)"
done
list=$(IFS=,; echo "${langs[*]}")
for side in before after; do
  W=$BASE/$side
  python3 "$W/datasets/generators/pqgen.py" generate --scale "$SCALE" --out "$W/datasets/generated" >/dev/null
  "$W/tools/orchestration/sandboxed.sh" make -C native-kernels all >/dev/null
  for l in "${langs[@]}"; do
    "$W/tools/orchestration/sandboxed.sh" make -C "implementations/$l" build > "$BASE/build-$side-$l.log" 2>&1 ||
      { echo "build failed: $side $l (see $BASE/build-$side-$l.log)" >&2; exit 1; }
  done
done
for side in before after; do
  (cd "$BASE/$side" && python3 benchmarks/harness/bench.py --engines "$list" --scale "$SCALE" --label "$side-$TASK" --track "$TRACK")
  for d in "$BASE/$side"/results/performance/*"-$SCALE-$side-$TASK"; do
    # The worktree also contains earlier, already committed result dirs.
    [[ -e "results/performance/$(basename "$d")" ]] && continue
    cp -r "$d" "results/performance/$(basename "$d")"
  done
done
printf '%s\n' "$@" > "results/performance/$TASK-runs-$STAMP.txt"
for side in before after; do git worktree remove --force "$BASE/$side"; done
