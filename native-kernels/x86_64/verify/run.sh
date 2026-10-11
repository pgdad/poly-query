#!/bin/sh
# Extra verification for the x86-64 assembly kernels (test tools only; nothing
# here is linked into libpqkernels). Usage: sh x86_64/verify/run.sh
# (run from native-kernels/). Builds into build/verify/.
# Optional: BASE=<git rev> also compares the machine code with that revision
# (disasm_compare.py; e.g. BASE=16e68a2 for the pre-CR-5 sources).
set -e
D=$(cd "$(dirname "$0")/../.." && pwd)
O=$D/build/verify
mkdir -p "$O"
SRC="$D/reference-c/pq_kernels_ref.c $D/reference-c/pq_dispatch.c $D/x86_64/pqk_x86_scalar.S $D/x86_64/pqk_x86_avx2.S $D/x86_64/pqk_x86_avx512.S"
CF="-O1 -g -w -I$D/include -I$D/reference-c"
gcc $CF -o "$O/guard_pages" "$D/x86_64/verify/guard_pages.c" $SRC
gcc $CF -o "$O/edge_cases" "$D/x86_64/verify/edge_cases.c" $SRC
gcc $CF -DSUM_CHUNK_ROWS=24 -DSUM_CHUNK_BLOCKS=1 -DSUM128_CHUNK_ROWS=64 -o "$O/edge_cases_chunk" "$D/x86_64/verify/edge_cases.c" $SRC
gcc $CF -DSUM_CHUNK_ROWS=24 -DSUM_CHUNK_BLOCKS=1 -DSUM128_CHUNK_ROWS=64 -o "$O/kernel_test_chunk" "$D/tests/kernel_test.c" $SRC -lm
gcc $CF -o "$O/abi_check" "$D/x86_64/verify/abi_check.c" "$D/x86_64/verify/abi_trampoline.S" $SRC
gcc $CF -o "$O/stress" "$D/x86_64/verify/stress.c" $SRC -lm
gcc $CF -DSUM_CHUNK_ROWS=24 -DSUM_CHUNK_BLOCKS=1 -DSUM128_CHUNK_ROWS=64 -o "$O/stress_chunk" "$D/x86_64/verify/stress.c" $SRC -lm
"$O/guard_pages" 300
"$O/edge_cases"
"$O/edge_cases_chunk"
"$O/kernel_test_chunk" 2000 | tail -1
"$O/abi_check"
"$O/stress" 3000
"$O/stress_chunk" 1000 7
python3 -I "$D/x86_64/verify/structure_check.py" | tail -1
if [ -n "$BASE" ]; then
  python3 -I "$D/x86_64/verify/disasm_compare.py" "$BASE" -R c_sign_q=c_i64min | tail -1
fi
