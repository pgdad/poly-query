#!/usr/bin/env bash
# Runs one phase of tools/validation/pqledger_interop.py for the arm64-asm-engine natively on
# the ARM host (default "spark"). The committed snapshot (HEAD) of the tool, the generators and
# the engine plus the local interop directory are staged into /srv/pqrunner/jobs/<job>; the
# build and the phase run as `pqrunner` in a transient systemd unit (no network, /home hidden,
# read-only system, only the job directory writable). The interop directory is copied back.
#
# Usage: arm_interop.sh <produce|consume|readback> <interop-dir>
set -euo pipefail
cd "$(dirname "$0")/../.."
PHASE=$1; DIR=$2
HOST=${PQ_ARM_HOST:-spark}
LANG_DIR=arm64-asm-engine
JOB="interop-$(date -u +%Y%m%dT%H%M%SZ)-$$"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST")
[[ -d $DIR ]] || { echo "arm_interop: no directory $DIR" >&2; exit 2; }
"${SSH[@]}" "mkdir -p ~/.pq-stage/$JOB/repo/$DIR"
git archive --format=tar HEAD tools/validation tests/apps/pqledger datasets/generators "implementations/$LANG_DIR" |
  "${SSH[@]}" "tar -C ~/.pq-stage/$JOB/repo -xf -"
rsync -a "$DIR/" "$HOST:.pq-stage/$JOB/repo/$DIR/"

"${SSH[@]}" "bash -s" -- "$JOB" "$PHASE" "$DIR" "$LANG_DIR" <<'REMOTE'
set -uo pipefail
JOB=$1; PHASE=$2; DIR=$3; LANG_DIR=$4
J=/srv/pqrunner/jobs/$JOB
L=~/.pq-out/$JOB
mkdir -p "$L"
sudo -n mkdir -p "$J/home" "$J/tmp"
sudo -n cp -a ~/.pq-stage/"$JOB"/repo "$J/"
sudo -n chown -R pqrunner:pqrunner "$J"
rm -rf ~/.pq-stage/"$JOB"
PY=/opt/pq/python/cpython-3.14.0-linux-aarch64-gnu/bin
unit() {  # unit <timeout-s> <cmd...>
  local t=$1; shift
  sudo -n systemd-run --quiet --pipe --wait --collect \
    -p User=pqrunner -p Group=pqrunner \
    -p IPAddressDeny=any -p PrivateNetwork=yes \
    -p ProtectHome=yes -p ProtectSystem=strict -p PrivateTmp=yes -p ReadWritePaths="$J" \
    -p NoNewPrivileges=yes -p PrivateDevices=yes -p CapabilityBoundingSet= \
    -p MemoryMax=32G -p RuntimeMaxSec="$t" \
    --working-directory="$J/repo" \
    -E HOME="$J/home" -E TMPDIR="$J/tmp" -E LANG=C.UTF-8 \
    -E PATH="$PY:/usr/local/bin:/usr/bin:/bin" "$@"
}
: > "$L/status"
unit 3600 make -C "implementations/$LANG_DIR" build > "$L/build.log" 2>&1; echo "build_exit=$?" >> "$L/status"
unit 3600 python3 tools/validation/pqledger_interop.py "$PHASE" --dir "$DIR" \
  --app "$LANG_DIR=implementations/$LANG_DIR/bin/pqledger" > "$L/phase.log" 2>&1
echo "${PHASE}_exit=$?" >> "$L/status"
sudo -n cp -a "$J/repo/$DIR" "$L/dir"
sudo -n chown -R "$(id -u):$(id -g)" "$L"
sudo -n rm -rf "$J"
REMOTE
rsync -a "$HOST:.pq-out/$JOB/dir/" "$DIR/"
mkdir -p "$DIR/arm-logs/$PHASE"
rsync -a "$HOST:.pq-out/$JOB/phase.log" "$HOST:.pq-out/$JOB/build.log" "$HOST:.pq-out/$JOB/status" "$DIR/arm-logs/$PHASE/"
"${SSH[@]}" "rm -rf ~/.pq-out/$JOB"
tail -n 20 "$DIR/arm-logs/$PHASE/phase.log"
cat "$DIR/arm-logs/$PHASE/status"
! grep -qv "=0$" "$DIR/arm-logs/$PHASE/status"
