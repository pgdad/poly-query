#!/usr/bin/env bash
# Runs a host-side command (conformance, benchmarks of merged engines) inside the
# agent sandbox with the repository as the only writable tree. Engines are
# AI-generated code; they must never run with access to the rest of $HOME.
# The repository's .git is read-only inside; no agent credentials are present.
#
# Usage: sandboxed.sh <command...>     (cwd = repository root)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BASE=${PQ_HOSTRUN_DIR:-/srv/polyquery/hostrun}
mkdir -p "$BASE/config" "$BASE/scratch"
chmod 700 "$BASE/config"
if [[ -n "$(ls -A "$BASE/config")" ]]; then
  echo "sandboxed.sh: $BASE/config must stay empty (no credentials for host runs)" >&2; exit 2
fi
PQ_RO_PATHS="$ROOT/.git${PQ_RO_PATHS:+:$PQ_RO_PATHS}" \
  exec "$ROOT/tools/orchestration/sandbox.sh" "$ROOT" "$BASE/config" "$BASE/scratch" -- "$@"
