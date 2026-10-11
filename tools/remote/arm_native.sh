#!/usr/bin/env bash
# Native AArch64 testing/benchmarking of the kernel library on a remote ARM host
# (default: "spark", an NVIDIA GB10 with Cortex-X925/A725 cores, SVE2, 128-bit VL).
#
# The kernel tree (trusted scaffolding + assembly) is copied to the host and run as
# the unprivileged system user `pqrunner` inside a transient systemd unit with no
# network, /home hidden, a read-only system and only the job directory writable.
# Benchmarks are pinned to one Cortex-X925 core.
#
# Usage: arm_native.sh <native-kernels-dir> <out-dir> [--bench] [--asan] [--hidden]
#   --hidden runs `make test-hidden` (expects <native-kernels-dir>/hidden/kernel_hidden_test.c)
# Outputs in <out-dir>: arm-test.log, arm-asan.log, arm-hidden.log, arm-bench.log, bench.jsonl, arm-host.json, arm-status
set -euo pipefail
SRC=$(realpath "$1"); OUT=$(realpath -m "$2"); shift 2
BENCH=0; ASAN=0; HIDDEN=0
for a in "$@"; do case $a in --bench) BENCH=1;; --asan) ASAN=1;; --hidden) HIDDEN=1;; *) echo "unknown arg $a" >&2; exit 2;; esac; done
HOST=${PQ_ARM_HOST:-spark}
BENCH_CPU=${PQ_ARM_BENCH_CPU:-9}          # a Cortex-X925 core on spark
TEST_CPUS=${PQ_ARM_TEST_CPUS:-5-9,15-19}  # all X925 cores
JOB="job-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$OUT"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST")

"${SSH[@]}" "mkdir -p ~/.pq-stage/$JOB"
rsync -a --delete --exclude build/ "$SRC/" "$HOST:.pq-stage/$JOB/native-kernels/"

# One remote script; each step runs in its own locked-down transient unit.
"${SSH[@]}" "bash -s" -- "$JOB" "$BENCH" "$ASAN" "$BENCH_CPU" "$TEST_CPUS" "$HIDDEN" <<'REMOTE' > "$OUT/arm-remote.log" 2>&1 || true
set -uo pipefail
JOB=$1; BENCH=$2; ASAN=$3; BENCH_CPU=$4; TEST_CPUS=$5; HIDDEN=$6
J=/srv/pqrunner/jobs/$JOB
L=~/.pq-out/$JOB   # logs are written by the ssh user, outside pqrunner's private tree
mkdir -p "$L"
sudo -n mkdir -p "$J"
sudo -n cp -a ~/.pq-stage/"$JOB"/native-kernels "$J/"
sudo -n chown -R pqrunner:pqrunner "$J"
rm -rf ~/.pq-stage/"$JOB"
unit() {  # unit <cpus> <timeout-s> <cmd...>
  local cpus=$1 t=$2; shift 2
  sudo -n systemd-run --quiet --pipe --wait --collect \
    -p User=pqrunner -p Group=pqrunner \
    -p IPAddressDeny=any -p PrivateNetwork=yes \
    -p ProtectHome=yes -p ProtectSystem=strict -p PrivateTmp=yes -p ReadWritePaths="$J" \
    -p NoNewPrivileges=yes -p PrivateDevices=yes -p CapabilityBoundingSet= \
    -p CPUAffinity="$cpus" -p MemoryMax=16G -p RuntimeMaxSec="$t" \
    --working-directory="$J/native-kernels" \
    -E PATH=/usr/bin:/bin -E LANG=C.UTF-8 "$@"
}
unit "$TEST_CPUS" 1800 make test-native > "$L/arm-test.log" 2>&1; echo "test_exit=$?" > "$L/arm-status"
if [ "$ASAN" = 1 ]; then unit "$TEST_CPUS" 1800 make test-asan > "$L/arm-asan.log" 2>&1; echo "asan_exit=$?" >> "$L/arm-status"; fi
if [ "$HIDDEN" = 1 ]; then unit "$TEST_CPUS" 1800 make test-hidden > "$L/arm-hidden.log" 2>&1; echo "hidden_exit=$?" >> "$L/arm-status"; fi
if [ "$BENCH" = 1 ]; then unit "$BENCH_CPU" 3600 make bench > "$L/arm-bench.log" 2>&1; echo "bench_exit=$?" >> "$L/arm-status"; fi
python3 - "$L/arm-host.json" <<'PY'
import json, platform, subprocess, sys
def sh(c):
    return subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()
info = {"hostname": platform.node(), "kernel": platform.release(), "machine": platform.machine(),
        "os": sh(". /etc/os-release; echo $PRETTY_NAME"), "gcc": sh("gcc --version | head -n1"),
        "cpus": sh("lscpu -e=CPU,MODELNAME,MAXMHZ"), "cpu_flags": sh("grep -m1 Features /proc/cpuinfo"),
        "sve_default_vector_length_bytes": sh("cat /proc/sys/abi/sve_default_vector_length"),
        "governor": sh("cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"),
        "mem_total": sh("grep MemTotal /proc/meminfo")}
json.dump(info, open(sys.argv[1], "w"), indent=1)
PY
sudo -n cp "$J/native-kernels/build/aarch64/bench.jsonl" "$L/" 2>/dev/null
sudo -n chown -R "$(id -u):$(id -g)" "$L"
sudo -n rm -rf "$J"
REMOTE
rsync -a "$HOST:.pq-out/$JOB/" "$OUT/"
"${SSH[@]}" "rm -rf ~/.pq-out/$JOB"
cat "$OUT/arm-status" 2>/dev/null || { echo "arm_native: no status (see $OUT/arm-remote.log)" >&2; exit 1; }
grep -q "^test_exit=0$" "$OUT/arm-status"
