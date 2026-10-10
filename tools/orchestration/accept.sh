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
"${PQ[@]}" import "$RUN" --merge | tail -n 1
just test-language "$lang" -q 2>&1 | tail -n 6
git add "results/correctness/$lang.json"
git commit -q -m "results: $lang conformance after $RUN" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SNVz4GnXkM5Wk9vgdbZLB2" || true
if [[ -n $NEXT ]]; then
  nohup "${PQ[@]}" wave --task "$NEXT" --langs "$lang" --attempt 1 --seed "$RANDOM" --timeout-min 330 --budget-usd 200 \
    --parallel 1 >> /srv/polyquery/waves.log 2>&1 &
  echo "accept: launched $NEXT for $lang"
fi
