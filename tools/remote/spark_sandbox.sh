#!/usr/bin/env bash
# PolyQuery agent sandbox on the ARM host (installed there as /opt/pq/agent/sandbox.sh
# by tools/remote/spark_agent_setup.sh). Same isolation model as
# tools/orchestration/sandbox.sh on the x86 host:
#   * bubblewrap via sudo, then setpriv to the invoking uid with no groups, no
#     capabilities and no_new_privs;
#   * $HOME is an empty tmpfs (only the Claude CLI is bound read-only); /srv is hidden
#     except this run's workspace, config and scratch directories;
#   * the environment is rebuilt from an allowlist (env -i);
#   * network access is not restricted (the agent needs the model API).
#
# Usage: sandbox.sh <workspace-dir> <agent-config-dir> <scratch-dir> -- <command...>
set -euo pipefail

if [[ $# -lt 5 || "$4" != "--" ]]; then
  echo "usage: $0 <workspace> <agent-config-dir> <scratch-dir> -- <command...>" >&2
  exit 2
fi
WS=$(realpath "$1"); CFG=$(realpath "$2"); SCR=$(realpath "$3"); shift 4
H=${HOME:?}
UID_=$(id -u); GID_=$(id -g)
mkdir -p "$SCR/tmp" "$SCR/cache"

# Emit --dir args (mode 0755) for every ancestor of $2 strictly below $1.
mkparents() {
  local root=$1 path=$2 rel acc part
  rel=${path#"$root"/}; acc=$root
  IFS=/ read -ra parts <<<"$rel"
  for part in "${parts[@]:0:${#parts[@]}-1}"; do
    acc=$acc/$part
    printf -- '--perms\0%s\0--dir\0%s\0' 0755 "$acc"
  done
}

BINDS=()
for p in "$CFG" "$WS" "$SCR"; do
  [[ $p == /srv/* ]] || { echo "sandbox: $p must be below /srv" >&2; exit 2; }
  mapfile -d '' -O "${#BINDS[@]}" BINDS < <(mkparents /srv "$p")
done
for p in "$H/.local/bin" "$H/.local/share/claude"; do
  mapfile -d '' -O "${#BINDS[@]}" BINDS < <(mkparents "$H" "$p")
done

exec sudo -n bwrap \
  --ro-bind / / \
  --dev /dev --proc /proc \
  --tmpfs "$H" --tmpfs /root --tmpfs /run/user --tmpfs /var/tmp --tmpfs /mnt --tmpfs /media --tmpfs /srv \
  "${BINDS[@]}" \
  --ro-bind "$H/.local/bin" "$H/.local/bin" \
  --ro-bind "$H/.local/share/claude" "$H/.local/share/claude" \
  --bind "$SCR/tmp" /tmp \
  --perms 0755 --dir "$H/.cache" --bind "$SCR/cache" "$H/.cache" \
  --bind "$CFG" "$CFG" \
  --bind "$WS" "$WS" \
  --bind "$SCR" "$SCR" \
  --chdir "$WS" \
  --unshare-pid --unshare-ipc --unshare-uts --hostname pq-sandbox \
  --die-with-parent \
  setpriv --reuid="$UID_" --regid="$GID_" --clear-groups --inh-caps=-all --bounding-set=-all --no-new-privs \
  env -i \
    HOME="$H" USER="$(id -un)" LOGNAME="$(id -un)" TERM=dumb LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    PATH="$H/.local/bin:/opt/pq/python/cpython-3.14.0-linux-aarch64-gnu/bin:/usr/local/bin:/usr/bin:/bin" \
    TMPDIR=/tmp CLAUDE_CODE_TMPDIR=/tmp DISABLE_AUTOUPDATER=1 \
    CLAUDE_CONFIG_DIR="$CFG" \
    GIT_AUTHOR_NAME="PolyQuery Agent" GIT_AUTHOR_EMAIL="agent@polyquery.invalid" \
    GIT_COMMITTER_NAME="PolyQuery Agent" GIT_COMMITTER_EMAIL="agent@polyquery.invalid" \
    PQ_SANDBOX=1 \
    "$@"
