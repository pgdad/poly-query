#!/usr/bin/env bash
# Runs tests/regression/robustness_probe.py natively on the ARM host (default "spark") against
# an engine that only runs there (arm64-asm-engine). Same isolation as tools/remote/arm_bench.sh:
# the committed snapshot (HEAD) is staged into /srv/pqrunner/jobs/<job>, and the build and the
# probes run as `pqrunner` in a transient systemd unit (loopback-only network, /home hidden,
# read-only system, only the job directory writable) on the Cortex-X925 cores.
#
# Usage: arm_probe.sh <lang> [robustness_probe.py args...]
# Output: results/correctness/robustness/<lang>.json, logs in results/correctness/robustness/arm-logs/<job>/
set -euo pipefail
cd "$(dirname "$0")/../.."
LANG_=$1; shift
HOST=${PQ_ARM_HOST:-spark}
CPUS=${PQ_ARM_TEST_CPUS:-5-9,15-19}
JOB="probe-$(date -u +%Y%m%dT%H%M%SZ)-$$"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST")
[[ -z $(git status --porcelain -- "implementations/$LANG_" tests/regression) ]] ||
  echo "arm_probe: note: uncommitted changes are NOT included (snapshot = HEAD)" >&2
"${SSH[@]}" "mkdir -p ~/.pq-stage/$JOB/repo"
git archive --format=tar HEAD "implementations/$LANG_" tests/regression | "${SSH[@]}" "tar -C ~/.pq-stage/$JOB/repo -xf -"

"${SSH[@]}" "bash -s" -- "$JOB" "$CPUS" "$LANG_" "$@" <<'REMOTE'
set -uo pipefail
JOB=$1; CPUS=$2; LANG_=$3; EXTRA=("${@:4}")
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
    -p IPAddressDeny=any -p IPAddressAllow=localhost -p PrivateNetwork=yes \
    -p ProtectHome=yes -p ProtectSystem=strict -p PrivateTmp=yes -p ReadWritePaths="$J" \
    -p NoNewPrivileges=yes -p PrivateDevices=yes -p CapabilityBoundingSet= \
    -p CPUAffinity="$CPUS" -p MemoryMax=96G -p RuntimeMaxSec="$t" \
    --working-directory="$J/repo" \
    -E HOME="$J/home" -E TMPDIR="$J/tmp" -E LANG=C.UTF-8 \
    -E PATH="$PY:/usr/local/bin:/usr/bin:/bin" "$@"
}
: > "$L/status"
unit 3600 make -C "implementations/$LANG_" build > "$L/build.log" 2>&1; echo "build_exit=$?" >> "$L/status"
unit 7200 python3 -u tests/regression/robustness_probe.py --engine "implementations/$LANG_/bin/polyquery" \
  --report "$J/probe.json" "${EXTRA[@]}" > "$L/probe.log" 2>&1
echo "probe_exit=$?" >> "$L/status"
sudo -n cp "$J/probe.json" "$L/" 2>/dev/null
sudo -n chown -R "$(id -u):$(id -g)" "$L"
sudo -n rm -rf "$J"
REMOTE
OUT=results/correctness/robustness
mkdir -p "$OUT/arm-logs/$JOB"
rsync -a "$HOST:.pq-out/$JOB/" "$OUT/arm-logs/$JOB/"
"${SSH[@]}" "rm -rf ~/.pq-out/$JOB"
# A partial run (--only) updates the probes it ran in an existing record.
if [[ -f $OUT/arm-logs/$JOB/probe.json ]]; then
  python3 - "$OUT/arm-logs/$JOB/probe.json" "$OUT/$LANG_.json" <<'PY'
import json, pathlib, sys
new, dest = json.loads(pathlib.Path(sys.argv[1]).read_text()), pathlib.Path(sys.argv[2])
if dest.exists():
    old = json.loads(dest.read_text())
    old["probes"].update(new["probes"])
    old.setdefault("reruns", []).append({"probes": list(new["probes"]), "started": new["started"]})
    new = old
dest.write_text(json.dumps(new, indent=1) + "\n")
PY
  rm "$OUT/arm-logs/$JOB/probe.json"
fi
cat "$OUT/arm-logs/$JOB/status" "$OUT/arm-logs/$JOB/probe.log"
! grep -qv "=0$" "$OUT/arm-logs/$JOB/status"
