#!/usr/bin/env bash
# Prepares the ARM host (default "spark") to run implementation agents natively
# (ADR-0016 / assembly-engines-plan §8: AArch64 agents run on the ARM host).
# Idempotent. Installs bubblewrap, the Claude CLI at the x86 host's version, the agent
# sandbox (/opt/pq/agent/sandbox.sh) and the run root /srv/pqagent/runs (mode 0700).
# No credential is installed here: the orchestrator copies the OAuth credential file
# into a run's config directory at launch and deletes it when the run ends.
#
# Usage: spark_agent_setup.sh [host]
set -euo pipefail
cd "$(dirname "$0")/../.."
HOST=${1:-${PQ_ARM_HOST:-spark}}
VERSION=$(claude --version | awk '{print $1}')
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST")

scp -q tools/remote/spark_sandbox.sh "$HOST:/tmp/pq-agent-sandbox.sh"
"${SSH[@]}" "bash -s" -- "$VERSION" <<'REMOTE'
set -euo pipefail
VERSION=$1
command -v bwrap >/dev/null || sudo -n apt-get install -y -q bubblewrap
if [[ "$("$HOME/.local/bin/claude" --version 2>/dev/null | awk '{print $1}')" != "$VERSION" ]]; then
  curl -fsSL https://claude.ai/install.sh | bash -s "$VERSION"
fi
sudo -n install -d -o root -g root -m 0755 /opt/pq/agent
sudo -n install -o root -g root -m 0755 /tmp/pq-agent-sandbox.sh /opt/pq/agent/sandbox.sh
rm -f /tmp/pq-agent-sandbox.sh
sudo -n install -d -o "$(id -u)" -g "$(id -g)" -m 0700 /srv/pqagent /srv/pqagent/runs
echo "claude $("$HOME/.local/bin/claude" --version)"
echo "python $(/opt/pq/python/cpython-3.14.0-linux-aarch64-gnu/bin/python3 --version 2>&1)"
echo "gcc $(gcc -dumpfullversion) / $(as --version | head -1)"
REMOTE
