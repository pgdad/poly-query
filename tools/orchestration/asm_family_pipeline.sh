#!/usr/bin/env bash
# Runs the later experiment families for one assembly engine in the order the six engines
# ran them (each family starts from the previous family's merged engine):
#   change-union-all -> refactor-plan-separation -> change-decimal38 -> optimize-latency
# Each family is a continuation chain with its own budget; a finished run must pass
# tools/validation/asm_engine_compliance.py before tools/orchestration/accept.sh merges it.
# Accepts are serialized with a lock because two pipelines (x86-64, AArch64) share the repo.
# Stops at the first family that does not succeed.
#
# Usage: asm_family_pipeline.sh <lang> <task>=<budget-usd> ...
set -euo pipefail
cd "$(dirname "$0")/../.."
LANG_=$1; shift
LOCK=/srv/polyquery/accept.lock
log() { echo "$(date -u +%FT%T+00:00) pipeline $LANG_: $*"; }
for spec in "$@"; do
  task=${spec%%=*}; budget=${spec#*=}
  log "start $task (budget \$$budget)"
  python3 tools/orchestration/pq_orchestrate.py chain --task "$task" --lang "$LANG_" --attempt 1 \
    --max-sessions 2 --total-budget-usd "$budget" --timeout-min 120
  chain=$(printf "%s\n" experiments/runs/chain-a-"$task"-"$LANG_"-a1-*.json | sort | tail -n 1)
  read -r outcome run < <(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));print(c["outcome"],c["sessions"][-1]["run_id"])' "$chain")
  if [[ $outcome != success ]]; then
    ( flock 9; tools/orchestration/accept.sh "$run" || true ) 9>"$LOCK"
    log "stop: $task outcome=$outcome ($run)"; exit 3
  fi
  if ! python3 tools/validation/asm_engine_compliance.py "$run"; then
    log "stop: $task $run violates the assembly policy (not merged)"; exit 4
  fi
  ( flock 9; tools/orchestration/accept.sh "$run" ) 9>"$LOCK"
  log "merged $task ($run)"
done
log "done"
