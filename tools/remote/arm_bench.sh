#!/usr/bin/env bash
# Benchmarks engines natively on the ARM host (default "spark") with the standard harness
# (benchmarks/harness/bench.py, same workload, scale and repetition settings as on the x86
# host). Used for engines that only run there (arm64-asm-engine); results are never compared
# across architectures.
#
# The committed snapshot (HEAD) is staged into /srv/pqrunner/jobs/<job>; the build, the
# dataset generation and the harness each run as the unprivileged user `pqrunner` in a
# transient systemd unit (no network except loopback for the HTTP benchmark, /home hidden,
# read-only system, only the job directory writable) pinned to the Cortex-X925 cores. That
# unit is the sandbox, so bench.py runs with --no-sandbox (recorded in the results together
# with this script's name).
#
# Usage: [PQ_BENCH_SCALE=1m] arm_bench.sh <label> <lang>[,<lang>...] [bench.py args...]
# Output: results/performance/<bench-id>/ (summary.json, raw.jsonl.gz, environment.json, arm-host.json)
set -euo pipefail
cd "$(dirname "$0")/../.."
LABEL=$1; ENGINES=$2; shift 2
HOST=${PQ_ARM_HOST:-spark}
CPUS=${PQ_ARM_TEST_CPUS:-5-9,15-19}   # the Cortex-X925 cores on spark
SCALE=${PQ_BENCH_SCALE:-1m}
JOB="bench-$(date -u +%Y%m%dT%H%M%SZ)-$$"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST")
[[ -z $(git status --porcelain -- implementations benchmarks datasets tests) ]] ||
  echo "arm_bench: note: uncommitted changes are NOT included (snapshot = HEAD)" >&2
IFS=, read -ra LANGS <<<"$ENGINES"
PATHS=(benchmarks datasets/generators datasets/manifests tests/conformance tools/environment)
for l in "${LANGS[@]}"; do PATHS+=("implementations/$l"); done
"${SSH[@]}" "mkdir -p ~/.pq-stage/$JOB/repo"
git archive --format=tar HEAD "${PATHS[@]}" ':(exclude)tests/conformance/hidden' |
  "${SSH[@]}" "tar -C ~/.pq-stage/$JOB/repo -xf -"
git rev-parse HEAD | "${SSH[@]}" "cat > ~/.pq-stage/$JOB/snapshot-commit"

"${SSH[@]}" "bash -s" -- "$JOB" "$CPUS" "$ENGINES" "$LABEL" "$SCALE" "$@" <<'REMOTE'
set -uo pipefail
JOB=$1; CPUS=$2; ENGINES=$3; LABEL=$4; SCALE=$5; EXTRA=("${@:6}")  # ssh re-splits words: bench.py args must not contain spaces
J=/srv/pqrunner/jobs/$JOB
L=~/.pq-out/$JOB
mkdir -p "$L"
sudo -n mkdir -p "$J/home" "$J/tmp"
sudo -n cp -a ~/.pq-stage/"$JOB"/repo "$J/"
cp ~/.pq-stage/"$JOB"/snapshot-commit "$L/"
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
IFS=, read -ra LANGS <<<"$ENGINES"
: > "$L/status"
for l in "${LANGS[@]}"; do
  unit 3600 make -C "implementations/$l" build > "$L/$l-build.log" 2>&1; echo "${l}_build_exit=$?" >> "$L/status"
done
unit 3600 python3 datasets/generators/pqgen.py generate --scale "$SCALE" > "$L/datasets.log" 2>&1
echo "datasets_exit=$?" >> "$L/status"
unit 21600 python3 benchmarks/harness/bench.py --engines "$ENGINES" --scale "$SCALE" --cpus "$CPUS" \
  --no-sandbox --label "$LABEL" "${EXTRA[@]}" > "$L/bench.log" 2>&1
echo "bench_exit=$?" >> "$L/status"
sudo -n cp -a "$J/repo/results/performance/." "$L/performance/" 2>/dev/null
python3 - "$L/arm-host.json" <<'PY'
import json, platform, subprocess, sys
def sh(c):
    return subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()
info = {"hostname": platform.node(), "kernel": platform.release(), "machine": platform.machine(),
        "os": sh(". /etc/os-release; echo $PRETTY_NAME"), "gcc": sh("gcc --version | head -n1"),
        "cpus": sh("lscpu -e=CPU,MODELNAME,MAXMHZ"), "governor": sh("cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"),
        "mem_total": sh("grep MemTotal /proc/meminfo"), "isolation": "systemd unit as pqrunner (tools/remote/arm_bench.sh)"}
json.dump(info, open(sys.argv[1], "w"), indent=1)
PY
sudo -n chown -R "$(id -u):$(id -g)" "$L"
sudo -n rm -rf "$J"
REMOTE
mkdir -p "results/performance/arm-logs/$JOB"
rsync -a --exclude performance "$HOST:.pq-out/$JOB/" "results/performance/arm-logs/$JOB/"
for d in $("${SSH[@]}" "ls ~/.pq-out/$JOB/performance 2>/dev/null"); do
  rsync -a "$HOST:.pq-out/$JOB/performance/$d/" "results/performance/$d/"
  cp "results/performance/arm-logs/$JOB/arm-host.json" "results/performance/$d/"
  echo "results: results/performance/$d"
done
"${SSH[@]}" "rm -rf ~/.pq-out/$JOB"
cat "results/performance/arm-logs/$JOB/status"
! grep -qv "=0$" "results/performance/arm-logs/$JOB/status"
