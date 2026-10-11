#!/usr/bin/env bash
# Accept a validated run: refresh telemetry, record, merge, sandboxed conformance,
# commit, and optionally launch the next phase for the language.
# Usage: accept.sh <run_id> [next-task]
set -euo pipefail
cd "$(dirname "$0")/../.."
RUN=$1; NEXT=${2:-}
PQ=(python3 tools/orchestration/pq_orchestrate.py)
"${PQ[@]}" telemetry "$RUN" >/dev/null
"${PQ[@]}" record "$RUN" >/dev/null
V=/srv/polyquery/runs/$RUN/validation.json
outcome=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['outcome'])" "$V")
lang=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['language'])" "/srv/polyquery/runs/$RUN/manifest.json")
git add experiments/runs
git commit -q -m "experiments: record $RUN ($outcome)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SNVz4GnXkM5Wk9vgdbZLB2" || true
if [[ $outcome != success ]]; then echo "accept: $RUN outcome=$outcome — not merged"; exit 3; fi
task=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['task'])" "/srv/polyquery/runs/$RUN/manifest.json")
# A debug-mutant fix is relative to a baseline with an injected defect that main never had: record only.
if [[ $task == debug-mutant || $task == kernel-debug-mutant ]]; then echo "accept: $RUN recorded (debug-mutant runs are not merged)"; exit 0; fi
record_only=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('record_only', False))" "/srv/polyquery/runs/$RUN/manifest.json")
if [[ $record_only == True ]]; then
  # Import as a branch (for the before/after benchmark) without merging into main.
  "${PQ[@]}" import "$RUN" | tail -n 1
  echo "accept: $RUN recorded and imported (record-only run, not merged)"; exit 0
fi
"${PQ[@]}" import "$RUN" --merge | tail -n 1
host=$(python3 -c "import json,sys;print(json.load(open('experiments/prompts/languages.json')).get(sys.argv[1],{}).get('agent_host',''))" "$lang")
if [[ -n $host ]]; then
  # Built and tested natively on the agent's host (public + hidden; the binary cannot run here).
  tools/remote/arm_engines.sh "results/correctness/arm64/$lang" "$lang" | tail -n 3 || true
  cp "results/correctness/arm64/$lang/$lang.json" "results/correctness/$lang.json"
  git add "results/correctness/arm64/$lang"
elif [[ $lang == *-asm ]]; then
  # Kernel cohort: public, ASan/UBSan and hidden kernel tests (AArch64 also natively on the ARM host).
  python3 tools/validation/kernel_correctness.py "$lang" | tail -n 1
else
  just test-language "$lang" -q 2>&1 | tail -n 6
fi
if [[ $task == native ]]; then
  tools/orchestration/sandboxed.sh make -C native-kernels all >/dev/null
  tools/orchestration/sandboxed.sh python3 tests/conformance/runner.py --engine "implementations/$lang/bin/polyquery" \
    --claimed --native native-kernels/build/x86_64/libpqkernels.so -q --report "results/correctness/$lang-native.json" | tail -n 1
  git add "results/correctness/$lang-native.json"
fi
git add "results/correctness/$lang.json"
git commit -q -m "results: $lang conformance after $RUN" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SNVz4GnXkM5Wk9vgdbZLB2" || true
if [[ -n $NEXT ]]; then
  nohup "${PQ[@]}" wave --task "$NEXT" --langs "$lang" --attempt 1 --seed "$RANDOM" --timeout-min 330 --budget-usd 200 \
    --parallel 1 >> /srv/polyquery/waves.log 2>&1 &
  echo "accept: launched $NEXT for $lang"
fi
