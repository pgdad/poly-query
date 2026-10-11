#!/usr/bin/env bash
# End-to-end AArch64 run of the engines on a remote ARM host (default "spark"):
# builds the native kernel library and each engine from a committed snapshot, then
# runs conformance (public + hidden) with and without native kernels.
#
# Engine code is AI-generated, so every build/test step runs as the unprivileged
# user `pqrunner` in a transient systemd unit: no network, /home hidden, read-only
# system, only the job directory writable. Toolchains are pinned to the host's
# versions under /opt/pq (installed by tools/remote/spark_toolchains.sh).
#
# Usage: arm_engines.sh <out-dir> [lang...]     (default: all six languages)
# Outputs in <out-dir>: <lang>-build.log, <lang>.json, <lang>-native.json,
#   native-lib.log, arm-host.json, toolchains.txt, status, snapshot-commit
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=$(realpath -m "$1"); shift
LANGS=("$@"); [[ ${#LANGS[@]} -gt 0 ]] || LANGS=(go rust java clojure python common-lisp)
HOST=${PQ_ARM_HOST:-spark}
CPUS=${PQ_ARM_TEST_CPUS:-5-9,15-19}   # the Cortex-X925 cores on spark
M2=${PQ_SHARED_M2:-/srv/polyquery/cache/m2}
JOB="engines-$(date -u +%Y%m%dT%H%M%SZ)-$$"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST")
mkdir -p "$OUT"
git rev-parse HEAD > "$OUT/snapshot-commit"
[[ -z $(git status --porcelain -- implementations native-kernels tests) ]] ||
  echo "arm_engines: note: uncommitted changes are NOT included (snapshot = HEAD)" >&2

"${SSH[@]}" "mkdir -p ~/.pq-stage/$JOB/repo ~/.pq-cache/m2"
git archive --format=tar HEAD implementations native-kernels tests datasets spec |
  "${SSH[@]}" "tar -C ~/.pq-stage/$JOB/repo -xf -"
# Offline Maven cache for the Clojure engine (org.clojure only; no other deps exist).
rsync -a "$M2/org/clojure" "$HOST:.pq-cache/m2/org/"

# ssh joins arguments into one command line: pass the language list comma-separated
"${SSH[@]}" "bash -s" -- "$JOB" "$CPUS" "$(IFS=,; echo "${LANGS[*]}")" <<'REMOTE' > "$OUT/remote.log" 2>&1 || true
set -uo pipefail
JOB=$1; CPUS=$2; IFS=, read -ra LANGS <<<"$3"
J=/srv/pqrunner/jobs/$JOB
L=~/.pq-out/$JOB
mkdir -p "$L"
sudo -n mkdir -p "$J/home/.m2/repository"
sudo -n cp -a ~/.pq-stage/"$JOB"/repo "$J/"
sudo -n cp -a ~/.pq-cache/m2/. "$J/home/.m2/repository/"
# Maven resolves the local repo from user.home (passwd), not $HOME: point the Clojure CLI at the job's copy.
sudo -n mkdir -p "$J/home/.clojure"
echo "{:mvn/local-repo \"$J/home/.m2/repository\"}" | sudo -n tee "$J/home/.clojure/deps.edn" >/dev/null
sudo -n chown -R pqrunner:pqrunner "$J"
rm -rf ~/.pq-stage/"$JOB"
P=/opt/pq
PY=$(ls -d $P/python/cpython-3.14.0-linux-aarch64-gnu/bin)
unit() {  # unit <timeout-s> <cmd...>
  local t=$1; shift
  sudo -n systemd-run --quiet --pipe --wait --collect \
    -p User=pqrunner -p Group=pqrunner \
    -p IPAddressDeny=any -p PrivateNetwork=yes \
    -p ProtectHome=yes -p ProtectSystem=strict -p PrivateTmp=yes -p ReadWritePaths="$J" \
    -p NoNewPrivileges=yes -p PrivateDevices=yes -p CapabilityBoundingSet= \
    -p CPUAffinity="$CPUS" -p MemoryMax=48G -p RuntimeMaxSec="$t" \
    --working-directory="$J/repo" \
    -E HOME="$J/home" -E LANG=C.UTF-8 \
    -E PATH="$PY:$P/jdk-27/bin:$P/go/bin:$P/rust/cargo/bin:$P/sbcl/bin:/usr/local/bin:/usr/bin:/bin" \
    -E JAVA_HOME=$P/jdk-27 -E SBCL_HOME=$P/sbcl/lib/sbcl \
    -E RUSTUP_HOME=$P/rust/rustup -E CARGO_HOME="$J/home/.cargo" \
    -E GOPATH="$J/home/go" -E GOCACHE="$J/home/.cache/go-build" -E GOFLAGS=-mod=mod \
    -E GOTOOLCHAIN=local -E GOPROXY=off "$@"
}
unit 300 sh -c 'java -version 2>&1 | head -n1; go version; rustc --version; cargo --version; python3 --version; clojure --version; sbcl --version' > "$L/toolchains.txt" 2>&1
unit 1800 make -C native-kernels all > "$L/native-lib.log" 2>&1; echo "native_lib_exit=$?" > "$L/status"
LIB=native-kernels/build/aarch64/libpqkernels.so
for l in "${LANGS[@]}"; do
  unit 3600 make -C "implementations/$l" build > "$L/$l-build.log" 2>&1; echo "${l}_build_exit=$?" >> "$L/status"
  unit 3600 python3 tests/conformance/runner.py --engine "implementations/$l/bin/polyquery" --claimed \
    --include-hidden -q --report "$J/$l.json" > "$L/$l-conformance.log" 2>&1
  echo "${l}_conformance_exit=$?" >> "$L/status"
  # Native-kernel mode only for engines that claim it (same gate as orchestrator validation);
  # the assembly engines do not load the kernel library.
  if unit 60 "implementations/$l/bin/polyquery" capabilities 2>/dev/null | grep -q native.kernels; then
    unit 3600 python3 tests/conformance/runner.py --engine "implementations/$l/bin/polyquery" --claimed \
      --include-hidden --native "$LIB" -q --report "$J/$l-native.json" > "$L/$l-native.log" 2>&1
    echo "${l}_native_exit=$?" >> "$L/status"
  else
    echo "${l}_native_exit=na" >> "$L/status"; rm -f "$L/$l-native.log" "$L/$l-native.json"
  fi
  sudo -n cp "$J/$l.json" "$J/$l-native.json" "$L/" 2>/dev/null
done
python3 - "$L/arm-host.json" <<'PY'
import json, platform, subprocess, sys
def sh(c):
    return subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()
info = {"hostname": platform.node(), "kernel": platform.release(), "machine": platform.machine(),
        "os": sh(". /etc/os-release; echo $PRETTY_NAME"), "gcc": sh("gcc --version | head -n1"),
        "cpus": sh("lscpu -e=CPU,MODELNAME,MAXMHZ"), "cpu_flags": sh("grep -m1 Features /proc/cpuinfo"),
        "sve_default_vector_length_bytes": sh("cat /proc/sys/abi/sve_default_vector_length"),
        "mem_total": sh("grep MemTotal /proc/meminfo")}
json.dump(info, open(sys.argv[1], "w"), indent=1)
PY
sudo -n chown -R "$(id -u):$(id -g)" "$L"
sudo -n rm -rf "$J"
REMOTE
rsync -a "$HOST:.pq-out/$JOB/" "$OUT/"
"${SSH[@]}" "rm -rf ~/.pq-out/$JOB"
cat "$OUT/status" 2>/dev/null || { echo "arm_engines: no status (see $OUT/remote.log)" >&2; exit 1; }
! grep -qv "=0$" "$OUT/status"
