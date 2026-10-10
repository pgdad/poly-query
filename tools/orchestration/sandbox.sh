#!/usr/bin/env bash
# PolyQuery agent sandbox.
#
# Runs a command inside a filesystem-isolated sandbox so that an implementation
# agent can see ONLY its own workspace plus read-only toolchains.
#
# Mechanism: bubblewrap launched via sudo (Ubuntu 24.04 AppArmor blocks
# unprivileged user namespaces; running bwrap as root avoids changing host
# security policy), then privileges are dropped to the invoking uid/gid with
# setpriv, with NO supplementary groups, no capabilities and no_new_privs set
# (so sudo/setuid binaries cannot be used to escape).
#
# Isolation properties (see docs/methodology/isolation.md):
#   * $HOME is an empty tmpfs; only whitelisted toolchain dirs are bound read-only.
#   * The PolyQuery repository, other workspaces, ~/.claude, ~/.aws, ~/.ssh,
#     ~/.docker, /run/user etc. are not visible.
#   * The environment is cleared (env -i) and rebuilt from an allowlist, so host
#     credentials in environment variables (e.g. AWS_*) are not inherited.
#   * Network access is NOT restricted (the agent needs the model API).
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
mkdir -p "$SCR/tmp" "$SCR/cache" "$SCR/gopath"
# Shared, writable Maven artifact cache (downloaded third-party artifacts only;
# never the host's settings.xml). Seeded once from the host cache.
M2=${PQ_SHARED_M2:-/srv/polyquery/cache/m2}
mkdir -p "$M2"
if [[ -d "$H/.m2/repository" && ! -e "$M2/.seeded" ]]; then
  cp -a "$H/.m2/repository/." "$M2/" 2>/dev/null || true; touch "$M2/.seeded"
fi

# Emit bwrap args that ro-bind each existing path, first creating any missing
# ancestor directories below $HOME with mode 0755 (bwrap would otherwise create
# them root-owned with mode 0700, which breaks absolute-path traversal).
ro_if_exists() {
  local p rel acc part
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    rel=${p#"$H"/}; acc=$H
    IFS=/ read -ra parts <<<"$rel"
    for part in "${parts[@]:0:${#parts[@]}-1}"; do
      acc=$acc/$part
      printf -- '--perms\0%s\0--dir\0%s\0' 0755 "$acc"
    done
    printf -- '--ro-bind\0%s\0%s\0' "$p" "$p"
  done
}

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

# /srv holds every run's workspace: hide it and re-bind only this run's paths.
SRV_BINDS=()
for pair in "$M2:$H/.m2/repository" "$CFG:$CFG" "$WS:$WS" "$SCR:$SCR"; do
  src=${pair%%:*}; dst=${pair#*:}
  if [[ $dst == /srv/* ]]; then
    mapfile -d '' -O "${#SRV_BINDS[@]}" SRV_BINDS < <(mkparents /srv "$dst")
  fi
done

mapfile -d '' TOOLBINDS < <(ro_if_exists \
  "$H/.cargo" "$H/.rustup" "$H/.local/bin" "$H/.local/share/claude" \
  "$H/.clojure" "$H/.local/share/uv")

PY_BIN=$(dirname "$(readlink -f "$(uv python find 3.14 2>/dev/null || command -v python3)")")
GO_BIN=""
for d in /snap/go/current/bin /usr/local/go/bin; do [[ -x "$d/go" ]] && { GO_BIN=$d; break; }; done

exec sudo -n bwrap \
  --ro-bind / / \
  --dev /dev --proc /proc \
  --tmpfs "$H" --tmpfs /root --tmpfs /run/user --tmpfs /var/tmp --tmpfs /mnt --tmpfs /media --tmpfs /srv \
  "${SRV_BINDS[@]}" \
  "${TOOLBINDS[@]}" \
  --bind "$SCR/tmp" /tmp \
  --bind "$SCR/cache" "$H/.cache" \
  --bind "$SCR/gopath" "$H/go" \
  --perms 0755 --dir "$H/.m2" --bind "$M2" "$H/.m2/repository" \
  --bind "$CFG" "$CFG" \
  --bind "$WS" "$WS" \
  --bind "$SCR" "$SCR" \
  --chdir "$WS" \
  --unshare-pid --unshare-ipc --unshare-uts --hostname pq-sandbox \
  --die-with-parent \
  setpriv --reuid="$UID_" --regid="$GID_" --clear-groups --inh-caps=-all --bounding-set=-all --no-new-privs \
  env -i \
    HOME="$H" USER="$(id -un)" LOGNAME="$(id -un)" TERM=dumb LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    PATH="$H/.local/bin:$H/.cargo/bin:${GO_BIN:+$GO_BIN:}$PY_BIN:/opt/sbcl/bin:${PQ_JAVA_HOME:-/usr/lib/jvm/jdk-27}/bin:/usr/local/bin:/usr/bin:/bin" \
    TMPDIR=/tmp CLAUDE_CODE_TMPDIR=/tmp \
    CLAUDE_CONFIG_DIR="$CFG" \
    GOPATH="$H/go" GOCACHE="$H/.cache/go-build" GOFLAGS=-mod=mod GOTOOLCHAIN=local GOPROXY=off \
    JAVA_HOME="${PQ_JAVA_HOME:-/usr/lib/jvm/jdk-27}" \
    CARGO_NET_OFFLINE=true \
    GIT_AUTHOR_NAME="PolyQuery Agent" GIT_AUTHOR_EMAIL="agent@polyquery.invalid" \
    GIT_COMMITTER_NAME="PolyQuery Agent" GIT_COMMITTER_EMAIL="agent@polyquery.invalid" \
    PQ_SANDBOX=1 \
    "$@"
