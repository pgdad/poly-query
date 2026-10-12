#!/usr/bin/env bash
# Runs tools/orchestration/mutate.py on the ARM host (default "spark") for an engine that only
# runs there (arm64-asm-engine): the committed engine, the public tests and mutate.py are staged
# under /srv/pqagent/mutants/<job>, each mutant is built and tested in the agent sandbox
# (/opt/pq/agent/sandbox.sh), and the accepted defect is copied back into
# experiments/controlled/defects/<lang>/. Hidden tests are not staged. The job directory is
# deleted afterwards.
#
# Usage: arm_mutate.sh <lang> [mutate.py args...]
set -euo pipefail
cd "$(dirname "$0")/../.."
LANG_=$1; shift
HOST=${PQ_ARM_HOST:-spark}
JOB="mut-$(date -u +%Y%m%dT%H%M%SZ)-$$"
R=/srv/pqagent/mutants/$JOB
PY=/opt/pq/python/cpython-3.14.0-linux-aarch64-gnu/bin/python3
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST")

"${SSH[@]}" "install -d -m 0700 /srv/pqagent/mutants $R $R/repo $R/work"
git archive --format=tar HEAD "implementations/$LANG_" tests tools/orchestration/mutate.py \
  ':(exclude)tests/conformance/hidden' ':(exclude)tests/kernels-hidden' |
  "${SSH[@]}" "tar -C $R/repo -xf -"
rc=0
"${SSH[@]}" "PQ_MUT_SANDBOX=/opt/pq/agent/sandbox.sh PQ_MUT_BASE=$R/work $PY $R/repo/tools/orchestration/mutate.py --lang $LANG_ $(printf '%q ' "$@")" || rc=$?
mkdir -p "experiments/controlled/defects/$LANG_"
if "${SSH[@]}" "test -d $R/repo/experiments/controlled/defects/$LANG_"; then
  rsync -a "$HOST:$R/repo/experiments/controlled/defects/$LANG_/" "experiments/controlled/defects/$LANG_/"
fi
"${SSH[@]}" "rm -rf $R"
exit "$rc"
