#!/bin/sh
# Extra verification for the x86-64 assembly kernels (test tools only; nothing
# here is linked into libpqkernels). Usage: sh x86_64/verify/run.sh
# (run from native-kernels/). Builds into build/verify/.
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
"$O/guard_pages" 300
"$O/edge_cases"
"$O/edge_cases_chunk"
"$O/kernel_test_chunk" 2000 | tail -1
"$O/abi_check"
