#!/bin/sh
# prof.sh FILE [N] - flat profile of a PQ_PROF sample file (src/prof.S):
# samples per engine function (addresses outside the engine count as "libc").
#   PQ_PROF=/tmp/p.txt bin/polyquery session ... ; sh bench/prof.sh /tmp/p.txt
HERE=$(cd "$(dirname "$0")/.." && pwd)
nm -n "$HERE/out/polyquery" | awk '$2 ~ /^[tT]$/ {print $1, $3}' > "${TMPDIR:-/tmp}/pqprof.syms"
python3 - "${TMPDIR:-/tmp}/pqprof.syms" "$1" "${2:-30}" <<'PY'
import sys, bisect, collections
syms = [(int(a, 16), n) for a, n in (l.split() for l in open(sys.argv[1]))]
addrs = [a for a, _ in syms]
c = collections.Counter()
for l in open(sys.argv[2]):
    a = int(l.split()[0], 16)
    i = bisect.bisect_right(addrs, a) - 1
    c[syms[i][1] if 0 <= i and a < addrs[-1] + 65536 else "libc"] += 1
tot = sum(c.values())
print("samples", tot)
for n, v in c.most_common(int(sys.argv[3])):
    print("%6d %5.1f%% %s" % (v, 100.0 * v / tot, n))
PY
