# PolyQuery native kernels: AArch64 assembly

This directory has the AArch64 (GNU `as`, AAPCS64) implementations of all 20
kernels declared in `../include/pq_kernels.h` (ABI version 1, revision 1:
the 16 original kernels plus the four 128-bit kernels of change request CR-4,
`../../spec/changes/kernels-i128.md`), in three variants:

| Variant | File | Status |
|---|---|---|
| `a64_scalar` (required) | `pq_a64_scalar.S` | 20/20 kernels, base A64 only (GPR + scalar FP) |
| `a64_neon` (required)   | `pq_a64_neon.S`   | 20/20 kernels, Advanced SIMD |
| `a64_sve` (optional)    | `pq_a64_sve.S`    | 20/20 kernels, SVE, vector-length agnostic |

Each kernel is exported as a global `pqk_<variant>_<kernel>` function with
`.type`/`.size`. The dispatcher in `../reference-c/pq_dispatch.c` finds them
through weak references. The sources were restructured under change request
CR-5 (`../../spec/changes/kernel-refactor.md`). After that, the throughput
pass described in the next section changed the hot loops of `a64_neon`. The
`a64_scalar` and `a64_sve` sources were not changed by that pass.

The first section covers the throughput work: the before/after table and
each optimization. The later sections describe the structure (CR-5) and the
algorithms, updated to the current NEON code.

## Throughput optimization of `a64_neon`

Goal: lower ns/element of `a64_neon` on `make -C native-kernels bench`
(4M elements, 17 workloads) with bit-identical results. The changes touch
only `pq_a64_neon.S` and `pq_a64_neon.h`. The scalar and SVE variants and
the shared `pq_a64_common.h` are unchanged.

### No measurements, so this is a model

There is no AArch64 hardware here. qemu timings say nothing about
performance, so I did not take or report any. Every "after" figure below is
an **expectation** from instruction counts and a simple machine model of the
target (Arm Cortex-X925). An independent before/after run on native
hardware follows. The model:

* **SIMD:** 4 × 128-bit pipes (given in the task). Simple ASIMD integer
  ops (ADD/SUB, CMxx, AND/BIT/BIF, UZP1, XTN) are fully pipelined with
  about 2 cycles of latency. UADALP, ADDV/UADDLV and vector-to-GPR moves
  run on fewer pipes and take longer (assumed 3–5 cycles).
* **Loads and stores:** about 3 loads per cycle and 2 stores per cycle.
  LD2/LD4 also use SIMD pipes for the de-interleave.
* **Integer:** about 8 ALUs and 2 multiply pipes; the front end decodes
  about 10 instructions per cycle.
* **Clock:** about 4 GHz, so 1 cycle ≈ 0.25 ns.
* **Memory is the deciding unknown.** The bench arrays (32 MiB per int64
  column, 64 MiB for int128) do not fit in any cache, so every streaming
  kernel also has a DRAM floor:
  *bytes per row ÷ single-core bandwidth*. I don't know the single-core
  DRAM bandwidth of the target. The table therefore gives two cases:
  * **low** = 40 GB/s, a floor of 0.8 cycles per 8-byte row;
  * **high** = 80 GB/s, or data in cache, a floor of 0.4 cycles per 8-byte
    row.

  The bitmaps of `bitmap_and` and `bitmap_popcount` are 512 KiB and stay
  in L2. The expected time is max(compute floor, memory floor).

The instruction mixes were counted mechanically from the disassembly of the
old and new loops (`objdump`, from each loop label to its back-branch).
"vec" means SIMD data-processing instructions per row.

### Before/after table (all 17 benchmark workloads)

| # | Workload (bench) | Before: hot loop, compute floor | After: hot loop, compute floor | DRAM bytes/row | Expected speedup, low / high | Why |
|---|---|---|---|---|---|---|
| 1 | `filter_i64_sel10` (LT, 10 % selected) | 16 rows/iter, 2.44 vec + 1.25 other instr/row; ≈0.61 c/row | 32 rows/iter, 1.47 vec + 1.0 other/row; ≈0.37 c/row | 8.4 | 1.0× / ≈1.45× | One CMGE per 2 rows instead of SUB+CMHS (LT is a "le" form). PACK32 builds the mask with 20 ops per 32 rows instead of 24. EMIT8 uses a u16 positions table with UADDW/UADDW2: 3 vector ops per 8 rows instead of 6. Pays off only once the stream is no longer DRAM-bound. |
| 2 | `filter_i64_bitmap` (GE) | 1.69 vec/row; ≈0.42 c/row | 1.09 vec/row; ≈0.27 c/row | 8.1 | 1.0× / ≈1.0–1.05× | CMGE form plus PACK32 and one 32-bit store. The old loop was already at the DRAM floor in both cases. |
| 3 | `count_i64_between` | 1.5 vec/row; ≈0.38 c/row | unchanged (BETWEEN keeps SUB+CMHS) | 8 | 1.0× / 1.0× | A genuine BETWEEN needs the range form. Other ops would get one compare per 2 rows. |
| 4 | `sum_i64` | LD2 + UADALP, 0.5 vec/row | unchanged | 8 | 1.0× / 1.0× | DRAM-bound (≈0.13–0.25 c/row of compute). |
| 5 | `sum_i64_validity` | 1.25 vec/row | unchanged | 8.1 | 1.0× / 1.0× | DRAM-bound. |
| 6 | `sum_f64` | 4 FADD accumulators, 0.5 vec/row | unchanged | 8 | 1.0× / 1.0× | DRAM-bound. |
| 7 | `minmax_i64` | 2.0 vec/row, but each of 2 accumulator pairs is updated twice per 8 rows through a CMGT→BIT chain of ~4 cycles: ≈1.0 c/row | 4 accumulator pairs, one update each per iteration: ≈0.5 c/row (throughput-bound) | 8 | ≈1.25× / ≈2.0× | Latency chain removed. Same instruction count. |
| 8 | `bitmap_and` | 64 B/iter | 128 B/iter | L2 | ≈1.0× / ≈1.0–1.05× | L2-bandwidth-bound. Half the loop overhead per byte. |
| 9 | `bitmap_popcount` | 9 vec ops / 64 B | 8 vec ops / 64 B (CNT + ADD tree + 1 UADALP .8h per 128 B) | L2 | ≈1.1× / ≈1.1× | 2 ops per 16 bytes is the CNT minimum. The data is L2-resident, so the 4 SIMD pipes, not memory, bound it. |
| 10 | `hash_i64` | 4-way GPR fmix64, 2 MUL/row | unchanged | 16 | 1.0× / 1.0× | MUL-bound (≈1 c/row with 2 multiply pipes) and close to the DRAM floor. See "not changed". |
| 11 | `compare_i64` (LT) | 1.19 vec/row | 1.09 vec/row (32 rows/iter, PACK32) | 16 | 1.0× / 1.0× | Two input streams: DRAM-bound in both cases. |
| 12 | `group_sum_i64_1024` | full id-check pass (re-reads the 16 MiB ids), then 12 instr/row (row loop with per-row `cbz counts`) | id check fused per 2048-row chunk (ids read from DRAM once); 9.0 instr/row, 4-row unrolled with LDP, two overflow-flag registers | 16 → 12 | ≈1.3× / ≈1.3× | 25 % less DRAM traffic, plus fewer instructions in a loop that is bound by 2 stores per row. |
| 13 | `gather_i64` | 4-row unrolled, 2.75 instr/row | 8-row unrolled + PRFM PLDL2KEEP 64 rows ahead, 3.9 instr/row | random | ≈1.0–1.5× (uncertain) | Random 8-byte reads from 32 MiB are bound by misses in flight. Prefetches retire without holding ROB/load-queue entries, so more misses overlap. The gain depends on how many L2 misses the core can track, which I don't know. |
| 14 | `filter_i128_sel10` (LT) | 5.5 vec/row; ≈1.4 c/row | 3.0 vec/row; ≈0.75 c/row | 16.4 | 1.0× / ≈1.7× | LT is a "le" form: a signed 128-bit compare (4 ops per 2 rows) instead of the 8-op subtract-and-range test. PACK8 takes 6 ops instead of 7. EMIT8 takes 3 vector ops instead of 6. |
| 15 | `count_i128_between` | 4.5 vec/row | unchanged (BETWEEN) | 16 | 1.0× / 1.0× | Range form needed. DRAM-bound at low; ≈1.1 c/row of compute vs 0.8 at high. |
| 16 | `sum_i128` | LD4 + UADALP, 1.0 vec/row | unchanged | 16 | 1.0× / 1.0× | DRAM-bound. |
| 17 | `minmax_i128` (validity) | 8.5 vec/row and a 16-cycle loop-carried chain per 8 rows; ≈2.1 c/row | skip test: 1.5 vec/row; ≈0.5 c/row | 16.1 | ≈1.3× / ≈2.6× | Exact updates run only for 8-row groups where some row's hi word reaches its lane's current min/max hi word. The valid-row count moved to a separate CNT pass. |

Overall I expect `minmax_i128`, `minmax_i64` and `group_sum_i64` to gain
clearly whatever the bandwidth, `filter_i128` and `filter_i64` to gain when
the cores are not DRAM-limited, `gather_i64` and `bitmap_popcount` to gain a
little, and everything else to stay within noise. No kernel is expected to
get slower on the benchmark data. The worst cases for other data are listed
under "Risks" below.

### The optimizations

**1. Predicate lane forms** (`PRED64_FORM`/`PRED_LANES`,
`PRED128_FORM`/`PRED128_2` in `pq_a64_neon.h`; used by filter_i64,
filter_i64_bitmap, count_i64, filter_i128, count_i128). `PRED_SETUP` still
produces the canonical `((x - lo) <=u span) ^ inv`. The selected set is a
run of `span + 1` consecutive values. Three shapes of that run can be tested
with one signed compare:

* **eq:** `span == 0`, the set {lo}. Test: `CMEQ x, lo`.
* **le:** `lo == MIN`, the set [MIN, hi]. Test: `CMGE hi, x`, with
  `hi = span ^ MIN`.
* **ge:** `lo + span == MAX`, the set [lo, MAX]. Test: `CMGE x, lo`.
* **rng:** anything else. Test: SUB + CMHS, as before.

Every op except a genuine BETWEEN is eq, le or ge. That includes NE (eq
inverted) and the empty sets, which are inverted always-true runs: LT MIN
and GT MAX become le with hi = MAX, and BETWEEN with a > b becomes le or
rng. A 64-bit compare therefore costs 1 op per 2 rows instead of 2. For
128-bit rows the same shapes cost 3 ops (eq: CMEQ, CMEQ, AND) or 4 ops
(le/ge: CMGT hi, CMEQ hi, CMHS lo, BIF) instead of the 8 of `RNG2`. The
setup branches once to a main-loop copy for the form; each kernel's loop is
one macro instantiated 4 times. The inversion and validity handling are
unchanged.

**2. 32-row masks** (`PACK16B`, `PACK32`, `PRED32`; filter_i64,
filter_i64_bitmap, compare_i64). Narrowing 64-bit lane masks to bytes costs
7 UZP1 per 16 rows; that part is unavoidable. The horizontal step (AND with
the bit weights, 3 ADDP, move to a GPR) now serves 32 rows instead of 16:
`ADDP a, b` merges both 16-row halves, and two more ADDP leave the four mask
bytes in lane 0. That is 20 ops per 32 rows instead of 24. The bitmap
writers store one 32-bit word per iteration. Their scalar tails grew to
0–31 rows, written as 1–4 bytes by `BITS_TAIL_STORE`.

**3. Index compaction with a u16 table** (`EMIT8`; filter_i64,
filter_i128). `.Lneon_selpos16` holds the positions as u16 (256 × 16 B =
4 KiB, generated by the assembler). One `LDR q` fetches them, and
`UADDW`/`UADDW2` widen them and add the row base in one step. That is 3
vector ops per 8 rows (UADDW, UADDW2, base increment) instead of 6 (3 UXTL,
2 ADD, increment). The store and cursor logic are unchanged, and so is the
over-store bound (cursor ≤ row, row + 8 ≤ n). filter_i128's `PACK8` now
uses three UZP1 to halfwords, AND with `.Lneon_bits8h`, and one `ADDV h`:
6 ops instead of 7.

**4. minmax_i64: four accumulator pairs.** With two pairs, each pair took two
dependent CMGT→BIT updates per 8-row iteration, a chain of about 8 cycles,
while the 16 SIMD ops need only about 4 cycles of issue. Giving each of the
4 input vectors its own pair makes every chain one update per iteration, so
the loop runs at its throughput. The pairs are merged after the loop. The
op count is the same.

**5. minmax_i128: hi-word window skip test.** A row can lower its lane's
min only if `x_hi <=s min_hi`, and raise its max only if `x_hi >=s max_hi`.
Each lane keeps the open interval (min_hi, max_hi) as two vectors:

* `wlo = min_hi + 1`;
* `span = (max_hi - min_hi) -sat 1` (unsigned saturating; `span = 0` is
  an empty window, e.g. before the first valid row).

So "strictly inside, cannot update" is `(x_hi - wlo) <u span`, one SUB and
one CMHI per 2 rows. The edge cases follow from the arithmetic: x ≤ min and
x ≥ max always fall outside, and span 0 makes everything "outside". The 8
results are narrowed to one byte per row (3 UZP1, XTN, FMOV) and checked in
a GPR against the validity byte, expanded to one byte per row by
`MUL 0x0101…01` and `AND 0x8040201008040201`. That is 13 SIMD ops per 8 rows
for the skip test, against about 64 for the exact update.

* **When a valid row is outside its window,** the group is re-loaded (the
  test overwrites the hi words) and goes through the old exact update
  (`MM2`/`MMV`).
* **Bursts:** at the start of the data, with sorted input, or when all hi
  words are equal, every group hits. So after a hit the exact update stays
  on for `MINMAX128_PLAIN` = 16 groups without the test. Then the windows
  are recomputed (6 ops) and the test resumes. Worst case: about one wasted
  test per 17 groups, about 1–2 %.
* **The count:** the valid-row count was 4 SUB per 8 rows. It is now a
  separate CNT pass over the validity bytes, 1/128 of the data bytes. The
  per-pair CMTST + USHR chain of the old loop runs only in the update path.
* **Exactness:** a skipped row cannot change any accumulator, so the result
  is the same as with the exact loop for every input.

**6. group_sum_i64: fused check, faster scatter-add.** The old kernel first
validated all ids in a separate pass, reading the 16 MiB of ids from DRAM,
then read them again for the accumulation. Now the rows go in chunks of
`NEON_GSUM_CHUNK` = 2048 (8 KiB of ids):

* **Per chunk:** the vector max-id check, then the scatter-add, which finds
  the ids in L1.
* **Error path:** if a later chunk fails the check, the rows of the earlier
  chunks are subtracted again (sums −= v, counts −= 1). Wrapping addition is
  exactly invertible and the operations commute, so the outputs are bit for
  bit untouched when `PQK_EINVAL` is returned, as the ABI requires. This
  path costs time only on invalid input.
* **Scatter-add:** 4 rows per iteration with LDP of ids and values,
  separate loop copies with and without `counts` (no per-row `cbz`), and two
  overflow-flag registers for even and odd rows, so the CSINC is not a
  serial chain. It still runs strictly in row order, so `PQK_OVERFLOW` is
  identical to the reference.
* **Validity path:** a sentinel-bit byte walker.
* **`ngroups >= 2^32`:** no special case is needed any more, because the
  64-bit compare with the max id never fails.

**7. gather_i64: index-ahead prefetch.** While at least
`NEON_GATHER_AHEAD + 8` = 72 rows remain, each 8-row iteration also loads
the indices 64 rows ahead (always inside `idx[0..m)`) and issues
`PRFM PLDL2KEEP` for their rows. The last 71 rows use 4-row and 1-row steps
without prefetch. Why PLDL2: the prefetch must not hold an L1 miss buffer
for its full DRAM latency, and the demand load 64 rows later finds the line
in L2.

**8. bitmap_popcount: 128 bytes per iteration.** CNT on 8 vectors, an ADD
tree (≤ 64 per byte) and one `UADALP .8h` (≤ 128 per halfword per
iteration). Blocks of `NEON_POPCNT_BLOCK` = 256 iterations keep the
halfwords ≤ 32768; each block is reduced with `UADDLV` into the GPR total.
This is 2 SIMD ops per 16 bytes, the minimum for a CNT-based count, down
from 2.25. Its other users are the `filter_i64_bitmap`/`compare_i64` tail
call and the `minmax_i128` count, which counts its bytes with its own short
loop.

**9. bitmap_and/or/andnot: 128 bytes per iteration** (4 LD1 ×4, 8 ops, 2
ST1 ×4). This halves the loop overhead per byte. Aliasing is still safe:
both inputs of an iteration are loaded before its stores.

### What was not changed, and why

* **`sum_i64`, `sum_f64`, `sum_i128`.** They need 0.13–0.5 cycles per row of
  compute, below the DRAM floor even at 80 GB/s, so no instruction change
  can show up on the benchmark.
* **`count_i64_between`, `count_i128_between`.** BETWEEN needs the range
  form. The counting SUB is already one op per mask vector, which is the
  minimum for combining masks. These loops get the form benefit for every
  other op.
* **`hash_i64`.** It stays the 4-way GPR pipeline, about 1 cycle per row
  bound by the two multiply pipes. A hybrid would also hash some rows in
  NEON, where a 64×64 multiply is 5 ops for 2 lanes (MUL .4s on swapped
  halves, UADDLP, SHL, XTN, UMLAL), about 17 SIMD ops per 2 rows. It gains
  only if the core has exactly 2 multiply pipes and is not DRAM-bound
  (16 bytes per row). With 4 multiply pipes the extra instructions would
  make it slower. Without hardware to decide, I left it alone.
* **`compare_fixed` and `minmax_f64`.** They are not benchmarked, so I
  left them alone.
* **SVE.** The `a64_sve` variant is untouched. It is written vector-length
  agnostic, one vector per iteration with gathered validity. At the
  128-bit vector length of the X925 it would need its own unrolling and
  restructuring, which this pass did not take on. The skip test of
  minmax_i128 and the predicate forms would carry over directly.

### Risks considered

* **Small inputs.** filter_i64, filter_i64_bitmap and compare_i64 now need
  32 rows for the vector loop and run up to 31 rows in scalar code (about
  6–8 instructions each), which is a little slower for n < 64. The bench
  uses n = 4M.
* **minmax_i128 on adversarial data.** Sorted input or input with a
  constant hi word costs at most one wasted 13-op test per 17 groups, so it
  is not slower than before (the update path also lost the per-group
  counting).
* **group_sum_i64 with an invalid id late in the input** now writes and
  then restores the outputs. The final state is identical; another thread
  reading the outputs concurrently would see intermediate values, but the
  ABI makes no promise about that.
* **gather_i64** runs about 40 % more instructions per row. If the core
  already reaches its miss limit without prefetch, those instructions are
  hidden behind the misses (≈1.0×).
* **Code size.** The neon object's `.text` grew from 7.5 KiB to 12.9 KiB
  because of the per-form loop copies, and `.rodata` from 2.4 KiB to
  4.4 KiB because of the u16 table. Only the loop of the active form runs,
  so the hot instruction footprint per call is smaller than before.

### Verification (functional, under qemu)

* `make -C native-kernels test-cross`: 20/20 PASS for `a64_scalar`,
  `a64_neon` and `a64_sve`; also with seeds 1–8 at 3000 iterations.
  `make -C native-kernels test` passes.
* **Throwaway guard-page harness** (not committed, since only assembly
  belongs here):
  * every input and output buffer of every kernel sits directly against a
    `PROT_NONE` page, at the start or the end;
  * all n from 0 to 140 plus random n up to 80 000;
  * all ops with a and b drawn from the data and from the extreme values;
  * seven 64-bit and nine 128-bit data distributions, including sorted
    data, constant data and constant hi words;
  * four validity patterns;
  * group_sum with invalid ids at random positions and NULL counts;
  * bitmaps up to 1 MiB, including an all-ones popcount;
  * aliasing of bitmap outputs.

  It reports 0 failures for `a64_neon`, `a64_scalar` and `a64_sve`.
* **Mutation checks** confirmed that the tests detect a broken form:
  * each `cmge`/`cmhs`/`cmeq` of the forms swapped for a neighbouring
    compare;
  * minmax_i128 window bounds made inclusive, window base off by one,
    saturation removed;
  * a skipped scatter-add row;
  * a missing undo subtraction;
  * a gather prefetch loop condition one block too long (caught as a
    guard-page fault).

  The minmax_i128 window mutations needed dedicated data: hi words in a
  small range with repeated extremes, and a constant-hi prefix that ends
  exactly when an update burst ends. Random data almost never reaches the
  boundary cases, because a group is updated exactly as soon as any row
  hits.
* **Shrunken block constants** in a temporary copy all pass:
  `NEON_POPCNT_BLOCK` 2, `NEON_GSUM_CHUNK` 16, `MINMAX128_PLAIN` 1,
  `NEON_GATHER_AHEAD` 4, `NEON_SUM64_BLOCK` 3, `NEON_SUM128_BLOCK` 24.
* **ABI audit of the disassembly:**
  * the registers each of the 20 NEON functions writes (including the
    popcount tail call) match its `Clobbers:` line exactly;
  * no function writes x18–x30, sp or v8–v15;
  * the `-fPIC -shared -Wl,-z,text` link succeeds;
  * `GNU_STACK` is RW;
  * all 60 `pqk_a64_*` symbols are exported with a non-zero size.

## CR-5 restructuring at a glance

* **Shared building blocks are defined once**, in three include files
  (C preprocessor `#include`, suffix `.h`, so the Makefile does not assemble
  them as translation units): `pq_a64_common.h` (all variants),
  `pq_a64_neon.h` (several NEON kernels) and `pq_a64_sve.h` (several SVE
  kernels). They contain only constants and GNU `as` macros; the NEON
  constant tables are a macro that `pq_a64_neon.S` invokes exactly once.
* **Every kernel has the same skeleton and a header comment** (Args, Result,
  Clobbers, Registers, Algorithm, Tail), and all labels follow one scheme
  (see below).
* **Nothing observable changed.** The object files assembled from the new
  sources are *byte-identical* to the ones before the restructuring: same
  `.text` and `.rodata` bytes, same symbols with the same values and sizes,
  same relocations, same section layout. This is how behaviour preservation
  and "no performance regression" were established (details under
  [Behaviour and performance](#behaviour-and-performance)). That held for
  CR-5. The throughput pass above then changed the NEON machine code on
  purpose.

## Module map

### Before (baseline 2b9f40d)

| File | Lines | Contents |
|---|---:|---|
| `pq_a64_macros.h` | 250 | 13 macros shared by all variants: `FUNC`/`ENDF`, `PRED_SETUP`, `SPRED`, `VBIT`, `LOAD_FMIX`, `FMIX1`, `PRED128_SETUP`, `SPRED128`, `MIN128`/`MAX128`, `MIN128V`/`MAX128V` |
| `pq_a64_scalar.S` | 709 | 20 scalar kernels; local macros `SBITOP`, `SWARPOP`, `SCMPBITS` |
| `pq_a64_neon.S` | 1753 | constant tables (`.Lbitsel16`, `.Lbits2d`, `.Lbits4s`, `.Lselpos`, `.Lselcnt`); 13 macros (`LOADADDR`, `PACK16`, `RANGE16`, `EMIT8`, `MMSTEP`, `NBITOP`, `CMP16`, `RNG2`, `RNG8`, `PACK8`, `MM2`, `MMV`, `REDMM`); 20 NEON kernels |
| `pq_a64_sve.S` | 937 | 10 macros (`SVE_VALID`, `ROWPRED`, `INVPRED`, `BITMAP_BLOCKS`, `RANGE_PRED`, `VBITOP`, `CMPEQ_PRED`, `CMPGT_PRED`, `RANGE128`, `SETUP128`); 20 SVE kernels |
| `README.md` | 345 | documentation |
| **Total (sources)** | **3649** | |

Problems that CR-5 addresses: variant-specific helpers were mixed with the
kernels; several blocks were written out more than once (the compare_i64
operator check and operand swap in all three files, the sum_i64/sum_i128
overflow epilogues in all three, the 192-bit limb fold in NEON and SVE, the
signed-zero fix-up of minmax_f64 in NEON and SVE, the group_sum
scatter-add four times, the bitmap byte tail, popcount of a partial byte,
validity-mask expansion and tail validity bytes many times in NEON, ...);
labels mixed three-letter prefixes (`.Lsf_`, `.Lnfb_`, `.Lvs8_`, ...) with
122 numeric labels (`1:`/`1b`); per-kernel comments had different shapes.

### After (CR-5, updated for the throughput pass)

| File | Lines | Contents |
|---|---:|---|
| `pq_a64_common.h` | 735 | Building blocks of all variants (43 macros + constants), in 11 sections: 1. constants (`PQK_*` status/op codes mirrored from the ABI header, `PQ_INT64_MIN/MAX`, `PQ_F64_PINF/NINF`, `PQ_FMIX_C1/C2`); 2. framing (`FUNC`, `ENDF`, `PQ_FILE_END`, `RET_*`); 3. operator validation and dispatch; 4. scalar predicates and validity bits; 5. exact integer accumulation and sum results; 6. min/max; 7. bitmaps and bit counting; 8. fmix64; 9. compare_fixed; 10. group_sum; 11. `LOADADDR` |
| `pq_a64_neon.h` | 482 | NEON building blocks used by more than one NEON kernel (27 macros): `NEON_TABLES` (all constant tables), validity masks, predicate lane forms (64- and 128-bit), 32-row mask packing, index compaction, 128-bit row helpers, bitmap-writer tails |
| `pq_a64_sve.h` | 198 | SVE building blocks used by more than one SVE kernel (10 macros): validity predicate, row loads, range predicates, 64-row block bitmap writer |
| `pq_a64_scalar.S` | 796 | 20 scalar kernels in the uniform skeleton; kernel-local macros `SCALAR_BITOP`, `SWARPOP`, `SCALAR_CMPBITS`, `MIN128V`/`MAX128V` |
| `pq_a64_neon.S` | 1997 | `NEON_TABLES` invocation, block-size constants, 20 NEON kernels; kernel-local macros `FILTER32_LOOP`, `BITMAP32_LOOP`, `SUM64_ACC`, `F64_ACC8`, `MMSTEP`, `F64_MINMAX8`, `COUNT8`, `COUNT_FORM`, `NEON_BITOP`, `CMP32`, `CMP32_LOOP`, `GS_ADD`, `GS_ACC_NV`, `GS_ACC_V`, `GATHER4`, `GATHER_PF4`, `PACK8`, `FILTER128_LOOP`, `COUNT128_8`, `COUNT128_FORM`, `SUM128_ACC`, `MM2`, `MMV`, `MM8`, `MM_WINDOWS`, `MM_INSIDE`, `REDMM` |
| `pq_a64_sve.S` | 873 | block-size constant, 20 SVE kernels; kernel-local macros `RANGE_PRED`, `SVE_BITOP`, `CMP_PRED` |
| `README.md` | — | this file |
| **Total (sources)** | **5081** | |

(At the end of CR-5 the NEON files had 362 + 1578 lines, 4542 in total.) The
sources grew by about 900 lines in CR-5 although duplicated code was removed:
the per-kernel header comments (Args/Result/Clobbers/Registers/Algorithm/
Tail for 60 functions), the documented macro interfaces and the section
markers account for more than that. The amount of *instruction* text fell.

Include order: every variant includes `pq_a64_common.h` first, then its own
`pq_a64_neon.h` / `pq_a64_sve.h`. All headers have include guards. Placement
rule: a block lives in a header iff more than one kernel or more than one
variant uses it; a macro used by exactly one kernel is defined directly
above that kernel (so one kernel can be read and changed without the
others).

## Kernel skeleton and naming

Every kernel in every file has this shape:

```
/* ========================================================================
 * <kernel>
 * Args:      argument registers (x0 data, x1 validity, ...)
 * Result:    return register and value
 * Clobbers:  every register the kernel writes, plus flags
 * Registers: role of each register inside the kernel
 * Algorithm: what the main loop does and why it is exact / safe
 * Tail:      how the rows after the last full vector / block are handled
 * ======================================================================== */
FUNC pqk_a64_<variant>_<kernel>
    // -- 1. arguments / empty input   op validation, constants, n == 0 / n < block
    // -- 2. main loop                 .L<variant>_<kernel>_main  (_main_v / _main_nv)
    //       (+ horizontal reduction of vector accumulators, where present)
    // -- 3. tail                      .L<variant>_<kernel>_tail  (or "tail: none")
    // -- 4. result                    .L<variant>_<kernel>_result
    error exits                        .L<variant>_<kernel>_inval
ENDF pqk_a64_<variant>_<kernel>
```

* The `Clobbers` lines were checked mechanically against the disassembly
  (registers written by each of the 60 functions, including the NEON
  popcount tail call); they match exactly.
* Label scheme: kernels use only named labels
  `.L<variant>_<kernel>_<step>` with `<variant>` ∈ {`scalar`, `neon`,
  `sve`}. Standard steps are `main`, `main_v`/`main_nv` (copies with / without
  validity), `tail`, `tail_row`, `result`, `inval`, `ok`; other steps have
  descriptive names (`block`, `fold`, `reduce`, `rec`, `diff`, ...). Labels
  inside macros are `.L<macro>_<step>\@`. There are no numeric labels left.
  The only data labels are the NEON tables, `.Lneon_<table>`.
* Macro arguments: macros that need both the W and the X view of a register
  take bare numbers (`SPRED 12, 7, 8, 9`), all others take full register
  names.
* In the scalar variant most kernels process one row per iteration, so their
  section 3 is "tail: none". In the SVE variant section 3 is always "none":
  the `WHILELO` predicate covers the last partial vector.

## Shared building blocks and their users

S = `a64_scalar`, N = `a64_neon`, V = `a64_sve`. "Users" are the kernels
that expand the block, directly or through another block.

### `pq_a64_common.h` (all variants)

| Block | Purpose | Users |
|---|---|---|
| `PQK_*`, `PQ_INT64_MIN/MAX`, `PQ_F64_PINF/NINF`, `PQ_FMIX_C1/C2` | constants (status/op codes as in the ABI header, value limits, fmix64 multipliers) | op checks, sum results, minmax inits (S N V), hash_i64 (S N V) |
| `FUNC`, `ENDF` | `.text`, `.globl`, `.type %function`, `.p2align 4`, `.size` | all 60 functions |
| `PQ_FILE_END` | `.note.GNU-stack` (non-executable stack) | the three variant files |
| `RET_INVALID_OP` | return `(size_t)-1` | filter_i64, filter_i64_bitmap, count_i64, compare_i64, filter_i128, count_i128 (S N V) |
| `RET_STATUS` | return a status constant | sum_i64, sum_i128, group_sum_i64 (S N V) |
| `RET_X`, `RET_W` | return a register | RET_X: count results of popcount, count_*, minmax_*, and of filter_*/compare_i64 in S and V; RET_W: group_sum_i64 (S N V) |
| `PRED_SETUP` | validate op, build the 64-bit range predicate `((x-lo) <=u span) ^ inv` | filter_i64, filter_i64_bitmap, count_i64 (S N V) |
| `PRED128_SETUP` | validate op before `*a`/`*b` are read, 128-bit range predicate | filter_i128, count_i128 (S N V) |
| `CMPOP_CHECK`, `CMPOP_SWAP` | compare_i64 op validation, EQ/GT + inversion reduction, LT/GE operand swap | compare_i64 (S N V) |
| `SPRED` | scalar 64-bit range predicate | filter_i64, filter_i64_bitmap, count_i64 (S; N tails) |
| `SPRED128` | scalar 128-bit range predicate | filter_i128, count_i128 (S; N tails) |
| `VBIT` | fetch the validity bit of one row | S: every kernel with a validity argument; N: tails of filter_i64, filter_i64_bitmap, filter_i128, count_i128, sum_i128, minmax_i128, plus minmax_f64 (zero scan) and group_sum_i64; V: minmax_f64 (zero scan), group_sum_i64 |
| `AND_VBIT` | AND a predicate bit with the row's validity (NULL-aware) | filter_i64, filter_i64_bitmap, count_i64, filter_i128, count_i128 (S; N tails) |
| `ADD128S`, `ADD192S` | add one sign-extended row to a 128-bit / 192-bit accumulator | sum_i64 / sum_i128 (S; N tails) |
| `FOLD_SUM64` | fold a block of split-half sums: `lo + (hi << 32)` | sum_i64 (N V) |
| `FOLD_LIMBS192` | fold a block of four 32-bit limb sums into 192 bits | sum_i128 (N V) |
| `BLOCK_END` | end row of the next bounded accumulation block | sum_i128 (N V), sum_i64 (V) |
| `SUM64_RESULT`, `SUM128_RESULT` | exact-sum overflow test, store, status | sum_i64, sum_i128 (S N V) |
| `MIN128`, `MAX128` | signed 128-bit min/max in GPR pairs (CMP/SBCS + CSEL) | minmax_i128 (S; N reduction and tail) |
| `MINMAX64_STEP`, `F64_MINMAX_STEP` | scalar min/max update (strict `<`/`>` for doubles) | minmax_i64, minmax_f64 (S; N tails) |
| `MINMAX_RESULT`, `MINMAX128_RESULT` | store outputs iff count > 0, return count | minmax_i64 (S N), minmax_f64 (S), minmax_i128 (S N) |
| `F64_FIRST_ZERO` | signed-zero fix-up (first valid zero, as the reference) | minmax_f64 (N V) |
| `SBITMAP_PUT`, `SBITMAP_FLUSH` | row-at-a-time bitmap writer | filter_i64_bitmap, compare_i64 (S) |
| `BITOP_STEP8`, `BITOP_BYTES` | 8-byte step / byte tail of and/or/andnot | bitmap_and/or/andnot (S N) |
| `LOWBITS` | mask of the low n bits | bitmap_popcount (S N V), group_sum_i64 (N) |
| `ADD_CNT8`, `ADD_POPCNT_LOW` | popcount of a (partial) byte with `CNT` | bitmap_popcount (N V), minmax_i128 valid-row count (N, `ADD_CNT8`) |
| `LOAD_FMIX`, `FMIX1` | fmix64 multipliers / one fmix64 round | hash_i64 (S N V / S N) |
| `CFX_BYTES`, `CFX_RESULT` | compare_fixed byte loop / per-record result | compare_fixed (S N) |
| `GSUM_ADD` | row-order scatter-add with overflow flag | group_sum_i64 (S V, through `GSUM_ROWS`; N has its own unrolled `GS_ADD`) |
| `GSUM_ROWS` | complete row-order accumulation loop | group_sum_i64 (S V) |
| `LOADADDR` | PC-relative address of a table | 13 NEON kernels (all that use a table) |

### `pq_a64_neon.h` (NEON kernels)

| Block | Purpose | Users (N) |
|---|---|---|
| `NEON_TABLES` | `.rodata`: `.Lneon_bitsel16`, `.Lneon_bits8h`, `.Lneon_bits2d`, `.Lneon_bits4s`, `.Lneon_selpos16` (u16 positions, 4 KiB), `.Lneon_selcnt` (the last two generated with `.rept`) | emitted once by pq_a64_neon.S; used by the kernels listed below |
| `VMASK2D`, `VMASK4S` | validity byte → 64-/32-bit lane masks (`CMTST`) | sum_f64, minmax_i64, minmax_f64, count_i64, count_i128 / sum_i64, group_sum_i64, sum_i128 |
| `LD8_VMASK2D`, `COUNT_VALID8` | 8 rows + validity masks; valid-row counter | sum_f64, minmax_i64, minmax_f64 / minmax_i64, minmax_f64 |
| `TAIL_VBYTE` | validity byte of a ≤ 7-row tail | sum_i64, sum_f64, minmax_i64, minmax_f64, count_i64, group_sum_i64 |
| `PRED64_FORM`, `PRED_LANES` (+`PRED_LANES1`, `RANGE_LANES`, `RANGE_SUB`, `RANGE_CMHS`) | choose the cheapest lane test of the 64-bit predicate (eq / le / ge: one compare; rng: `SUB` + `CMHS`) and evaluate it on a register list | filter_i64, filter_i64_bitmap, count_i64 |
| `PACK16B`, `PACK32`, `PRED32` | 16 lane masks → byte masks (`UZP1` ×7); 2 × 16 byte masks → 32-bit row mask; complete 32-row predicate mask | filter_i64, filter_i64_bitmap / + compare_i64 (`PACK16B`, `PACK32`) |
| `EMIT8_SETUP`, `EMIT8` | table-driven index compaction of 8 rows (u16 positions, `UADDW`/`UADDW2`) | filter_i64, filter_i128 |
| `PRED128_BCAST`, `PRED128_FORM`, `PRED128_2`, `PRED128_8`, `RNG2` | 128-bit predicate on LD2-split rows: broadcast, choice of form, evaluation for 2 / 8 rows, range form | filter_i128, count_i128 |
| `LD2X4` | 8 pqk_i128 rows → lo/hi word vectors | filter_i128, count_i128, minmax_i128 |
| `ADDV2X` | horizontal sum of two lane counters | count_i64, count_i128 |
| `BITS_TAIL_PUT`, `BITS_TAIL_STORE`, `POPCOUNT_TAILCALL` | scalar tail (0–31 rows, 1–4 bytes) and popcount result of the 32-row bitmap writers | filter_i64_bitmap, compare_i64 |

### `pq_a64_sve.h` (SVE kernels)

| Block | Purpose | Users (V) |
|---|---|---|
| `SVE_VALID`, `ROWPRED` | gathered validity bits → valid-row predicate `p1` | all row kernels except bitmap ops, popcount, hash, compare_i64, compare_fixed, gather (12 kernels) |
| `SVE_LD64` | load rows, row numbers, `p1` | filter_i64, sum_i64, sum_f64, minmax_i64, minmax_f64, count_i64 |
| `SVE_LD128` | `LD2D` rows, row numbers, `p1` | filter_i128, count_i128, sum_i128, minmax_i128 |
| `INVPRED` | inversion predicate `p6` | filter_i64, filter_i64_bitmap, count_i64, compare_i64, filter_i128, count_i128 |
| `PRED_BCAST64`, `RANGE64` | broadcast / evaluate the 64-bit range predicate | filter_i64, filter_i64_bitmap, count_i64 |
| `SETUP128`, `RANGE128` | broadcast / evaluate the 128-bit range predicate | filter_i128, count_i128 |
| `BITMAP_BLOCKS` | 64-row block bitmap writer + count result (any VL) | filter_i64_bitmap, compare_i64 |

What is deliberately *not* factored: loop control (`add`/`cmp`/`b.lo`,
`incd`/`whilelo`/`b.first`), plain register initialisation (`mov x, #0`,
`movi v, #0`), the explicitly interleaved 4-row fmix64 pipeline of NEON
`hash_i64`, and two- or three-line compositions of shared macros. A
mechanical scan for repeated runs of four or more instruction lines across
all sources now finds only such initialisation sequences.

## Behaviour and performance

This section documents CR-5, the pure restructuring. The NEON code has
changed since then; see the throughput section at the top for that.

**Verification that nothing changed.** Before touching anything, the three
baseline objects were assembled and kept. After every step the new sources
were assembled with the same toolchain (`aarch64-linux-gnu-gcc -c`) and
compared:

* `.text`, `.rodata`, `.data`, `.bss` and `.note.GNU-stack`: byte for byte;
* the symbol table (value, size, type, binding of all 60 functions);
* the section headers (sizes, alignment) and all relocations.

All three variants are identical in all of these. A deliberately changed
instruction was confirmed to be detected. Since the linked library is built
from the same objects in the same order, every kernel runs exactly the same
instructions at the same addresses and alignments as before.

**Expected effect of each change on the Cortex-X925 target.**

| Change | Effect on generated code | Expected performance effect |
|---|---|---|
| Shared blocks moved into `pq_a64_common.h` / `pq_a64_neon.h` / `pq_a64_sve.h` macros | none (the macro expansions are the former instruction sequences, operand for operand) | none |
| `PRED_SETUP` etc. use named constants (`PQK_*`, `PQ_INT64_*`), `LOAD_FMIX` derives its `MOVZ`/`MOVK` halves from `PQ_FMIX_C1/C2` | identical encodings | none |
| Tables emitted by `NEON_TABLES`, renamed `.Lneon_*` | identical `.rodata` bytes, alignment and relocations | none |
| Labels renamed to `.L<variant>_<kernel>_<step>`, numeric labels removed | local labels are not emitted; branch offsets identical | none |
| Kernel-local macros (`SUM64_ACC`, `CMP16_LOOP`, `MIN128V`, ...) | identical expansions | none |
| Header comments, section markers, README | none | none |

So the independent before/after measurement on native hardware should show
only run-to-run noise. Any difference larger than noise would point to an
environmental cause (frequency, placement), not to these sources.

## Test results

All AArch64 testing ran under **qemu-user emulation** (qemu 8.2.2,
`aarch64-linux-gnu-gcc` 13.3). The emulated runs check correctness only.
No AArch64 hardware was available. State after the throughput pass:

```
$ make -C native-kernels test-cross
== AArch64 (qemu-user emulation; functional only) ==
available variants: reference,a64_sve,a64_neon,a64_scalar (default: a64_sve)
  a64_scalar  20/20 kernels  PASS
  a64_neon    20/20 kernels  PASS
  a64_sve     20/20 kernels  PASS
kernel tests: 3 variant(s) tested, 0 failure(s)
```

Also run:

* `make -C native-kernels test` passes. On this x86-64 host its native and
  ASan stages test only the C reference, because there is no `x86_64/`
  directory.
* The cross test binary with seeds 1–8 at 3000 iterations: 0 failures.
* SVE at VL = 128, 384, 512 and 2048 bits
  (`-cpu max,sve-default-vector-length=N`): `a64_sve` and `a64_neon`
  20/20 PASS.
* The checks of the throughput pass, described there under
  "Verification": the guard-page harness, mutation checks, shrunken block
  constants, the clobber audit and the PIC link.

The harnesses are throwaway programs and are not committed, because only
assembly belongs here. The block sizes are named constants
(`NEON_SUM64_BLOCK`, `NEON_POPCNT_BLOCK`, `NEON_SUM128_BLOCK`,
`NEON_GSUM_CHUNK`, `NEON_GATHER_AHEAD`, `MINMAX128_PLAIN`,
`SVE_SUM_BLOCK`), so the flush and boundary paths can be exercised by
redefining them in a temporary copy.

## Benchmarks

**None measured.** `make bench` runs only on the native architecture. This
machine is x86-64, where `make bench` measures only the C reference and the
x86 variants. Timings under qemu are meaningless, so I did not record or
report any. On AArch64 hardware, `make -C native-kernels bench` writes the
`a64_scalar` / `a64_neon` / `a64_sve` numbers to
`build/aarch64/bench.jsonl`. The expected NEON effects are in the
before/after table at the top.

As a rough guide only, here are instructions per row of the hot loops
(no validity), counted from the disassembly. They are **not**
measurements. "before" is the state before the throughput pass.

| kernel (no validity) | a64_scalar | a64_neon before | a64_neon now |
|---|---|---|---|
| filter_i64 | 11 | 3.7 (59 per 16 rows) | 2.5 (79 per 32 rows) for EQ/NE/LT/LE/GT/GE, 3.0 for BETWEEN |
| count_i64 | 10 | 1.9 | 1.4 for EQ..GE, 1.9 for BETWEEN |
| sum_i64 (exact) | 8 | 1.0 (LD2 + UADALP/SADALP) | unchanged |
| sum_f64 | 6 (one serial FADD chain) | 0.9 (8 independent partial sums) | unchanged |
| minmax_i64 | 11 | 2.4 (latency-bound) | 2.4 (four independent accumulator pairs) |
| compare_i64 | ≈14 | 1.8 | 1.5 |
| bitmap_and (per byte) | ≈0.9 | 0.16 | 0.13 |
| bitmap_popcount (per byte) | ≈1.75 (SWAR) | 0.19 (CNT) | 0.16 |
| hash_i64 | 10 | 7.75 (4-way interleaved GPR) | unchanged |
| group_sum_i64 | ≈12 | 12.6 (check pass + row loop) | 9.6 (fused check + 4-row loop) |
| gather_i64 | ≈4 | 2.75 | 3.9 (with prefetch) |
| filter_i128 | 13 | 7.5 (60 per 8 rows) | 4.5–5.0 for EQ..GE, 7.0 for BETWEEN |
| count_i128 | 12 | 5.4 | 3.4 for LT/LE/GT/GE, 5.4 for BETWEEN |
| sum_i128 (exact) | 9 | 1.6 (2×LD4 + 8×U/SADALP per 8 rows) | unchanged |
| minmax_i128 | 12 | 6.9 | 2.75 with the skip test, 7.1 in the update path |

## Design decisions (algorithms)

### One predicate form for every op
`PRED_SETUP` turns `(op, a, b)` into `pred(x) = ((uint64)(x - lo) <= span) XOR inv`.
For example, LT becomes `[INT64_MIN, a-1]`, and an empty set (LT `INT64_MIN`,
GT `INT64_MAX`, BETWEEN with `a > b`) becomes an inverted always-true range.
The full table is in `pq_a64_common.h`. Because of this, each predicate
kernel has a single branch-free inner loop: `SUB`+`CMP`+`CSET` in scalar
code (`SPRED`), `SUB`+`CMHS` in NEON (`RANGE_LANES`), `SUB`+`CMPHS` in SVE
(`RANGE64`). NEON also tests three special shapes of the range with a
single compare (`PRED64_FORM`, see the throughput section): `CMEQ` for
EQ/NE, `CMGE` for LT/LE and GT/GE. The inversion costs one `EOR` on a
32-bit mask (NEON) or on a predicate (SVE). Invalid ops are rejected by checking `op` as an unsigned
32-bit value, before anything is read, so `n == 0` still returns
`(size_t)-1` for a bad op, as in the reference. Only the W view of `int`
arguments is used, because AAPCS64 leaves the upper 32 bits undefined.
compare_i64 uses its own reduction (`CMPOP_CHECK`/`CMPOP_SWAP`): every op
becomes EQ or GT plus an inversion bit, with LT/GE swapping the operands.

### Validity bitmaps
* Scalar: the bit is fetched per row (`VBIT`: byte load + shift). When the
  pointer is NULL, a well-predicted branch skips the fetch (`AND_VBIT`).
* NEON: `LD1R` replicates one validity byte, and `CMTST` against per-lane
  bit constants turns it into 64-bit lane masks for 8 rows (`VMASK2D`,
  `VMASK4S`). Index and bitmap filters build a 16-bit row mask instead and
  `AND` it with an unaligned `LDRH` of the validity. Tails take one byte
  (`TAIL_VBYTE`) and shift it per row.
* SVE: `LD1B` gathers each lane's byte (`row >> 3`) under the loop
  predicate, then shifts and tests it (`SVE_VALID`). The vector length need
  not be a multiple of 8 rows, so a gather is the only general method that
  never reads past `ceil(n/8)` bytes.

### filter_i64 (index output)
NEON uses a 256×8 table of u16 positions (`.Lneon_selpos16`) and a
256-entry popcount table (`.Lneon_selcnt`). The assembler generates both
from their definitions with `.rept`/`.if`; no external generator is
involved. For each 8-row mask byte, `EMIT8` does the following:

1. loads the 8 positions (one `LDR q`);
2. widens them to u32 and adds the row base in one step
   (`UADDW`/`UADDW2`);
3. stores 32 bytes unconditionally;
4. advances the cursor by the popcount.

The main loop takes 32 rows (four mask bytes) per iteration. The over-store
stays inside the documented capacity (`>= n`): for each byte the cursor is
`k <= i` and `i + 8 <= n`. The scalar variant uses the same idea one row at
a time. SVE uses `COMPACT` and a predicated truncating `ST1W`, so it never
over-stores.

### sum_i64 exact overflow handling
The reference accumulates in 128 bits, and only the final sum must fit in
int64 (`SUM64_RESULT`).
* Scalar: `ADDS`/`ADC` into a 128-bit register pair (`ADD128S`).
* NEON: `LD2 {.4s}` splits every int64 into an unsigned low half and a
  signed high half. `UADALP`/`SADALP` accumulate them pairwise into 64-bit
  lanes, using two independent accumulator pairs. A block is at most 2^24
  iterations, so the lanes stay below 2^58 and 2^57 and cannot wrap. Each
  block is folded into a 128-bit GPR total as `lo + (hi << 32)`
  (`FOLD_SUM64`).
* SVE: the same split, with `AND`/`ASR` and merging `ADD` in blocks of 2^24
  rows, reduced with `UADDV`.
* In every variant, overflow means the 128-bit result is outside int64.
  Intermediate overflow that later cancels out is therefore correctly
  reported as OK.

### Floating point
* `sum_f64`: scalar is strictly sequential and bit-identical to the
  reference. Invalid rows add `+0.0`, which changes nothing because the
  running sum can never be `-0.0`. NEON keeps 8 lane-wise partial sums, SVE
  keeps VL/64 of them. The header's tolerance allows this reassociation.
* `minmax_f64`: scalar uses `FCMP`/`FCSEL` with the reference's strict
  comparisons, starting from ±inf (`F64_MINMAX_STEP`). NEON uses
  `FMINNM`/`FMAXNM`; invalid lanes are forced to all-ones with `ORN`, which
  is a quiet NaN that `FMINNM` ignores. The only lane-order-dependent part is
  the sign of a zero result. The reference returns the *first valid zero* in
  row order in that case, so NEON and SVE re-scan for it when the result is
  ±0 (`F64_FIRST_ZERO`). That makes them bit-identical to the reference, not
  just `==`-equal.

### Kernels where SIMD gives little and why
* `hash_i64` (NEON): Advanced SIMD has no 64×64-bit multiply. Building one
  from `UMULL`/`MUL .2s`/`MLA`/`SHLL` costs about 7 vector ops per multiply
  for 2 lanes, roughly 10 ops per element against 6 GPR ops. The NEON
  variant therefore uses a 4-way interleaved GPR pipeline. SVE does have
  `MUL .d`, so the SVE version is fully vectorized.
* `group_sum_i64`: scatter-adds with possible id conflicts cannot be done
  in NEON or base SVE. Id validation is vectorized (`UMAX` of masked ids,
  or `UMAX`+`INCP` in SVE). The accumulation is scalar in row order, with
  an `ADDS` + `CSINC` overflow flag (`GSUM_ADD`; NEON uses its unrolled
  `GS_ADD`), so the overflow flag matches the reference exactly.
  * Scalar and SVE validate every valid row before any output is written.
  * NEON validates and accumulates per 2048-row chunk and undoes the
    earlier chunks if a later one fails. Either way the outputs are
    untouched on EINVAL.
* `gather_i64`: NEON has no gather, so it uses unrolled scalar loads plus a
  prefetch of the rows 64 indices ahead. SVE uses an `LD1W` + `LD1D`
  gather.

### Bitmap outputs and counts
* NEON writes 32 rows per 32-bit `STR`, and a scalar tail writes the last
  1–4 zero-padded bytes (`BITS_TAIL_PUT`/`BITS_TAIL_STORE`). The returned
  count is the popcount of the finished bitmap, via a tail call into the
  `bitmap_popcount` loop (`POPCOUNT_TAILCALL` to the internal entry
  `.Lneon_bitmap_popcount_bytes`). That pass is about 1/64 of the input
  bytes and keeps the main loop short.
* SVE builds 64-row blocks with `ORV` of `1 << (row & 63)` and stores one
  word per block (byte stores for the last partial block): `BITMAP_BLOCKS`.
  This works for any VL.

### Bitmap and/or/andnot aliasing
`out` may equal `a` or `b`. Every chunk is loaded from both inputs before it
is stored, and there is no overlapping "last vector" trick. That trick would
be wrong for `andnot` when `out == b`. NEON's main loop takes 128 bytes;
the tails step down 16 → 8 → 1 bytes (`BITOP_STEP8`, `BITOP_BYTES`).

### compare_fixed
* NEON compares 16-byte `CMEQ` chunks. `SHRN #4` packs them into a 64-bit
  nibble mask, `CMN #1` tests for all-equal, and `RBIT`+`CLZ` finds the
  first differing byte. After that come one 8-byte step (`REV` makes the
  words big-endian, so unsigned compare gives lexicographic order) and
  single bytes (`CFX_BYTES`, shared with the scalar variant, as is the
  per-record result `CFX_RESULT`).
* SVE uses `CMPNE` on byte vectors, then `BRKB`+`LASTA` to pick out the
  first differing bytes.

### ABI conformance
* Every function is a leaf. NEON's `filter_i64_bitmap` and `compare_i64`
  tail-call a local label, which is a plain branch. No function uses the
  stack or `sp`.
* Only caller-saved registers are used: x0–x17, v0–v7, v16–v31, and
  z0–z7, z16–z31 plus p0–p15 for SVE. x18 and x19–x29 are never touched,
  and neither are v8–v15/z8–z15, whose low halves d8–d15 are callee-saved.
  This was checked on the disassembly of every function.
* All loads and stores are ordinary (non-exclusive) accesses, so unaligned
  pointers are fine on AArch64 Linux. No load ever spans past a buffer end.
* Constant tables live in `.rodata` and are addressed with `ADRP`/`:lo12:`
  (`LOADADDR`), which is position independent and works both static and in
  a shared library.

### 128-bit kernels (CR-4)

A `pqk_i128` is `{uint64 lo; int64 hi}`, which is the little-endian int128.
Scalar code keeps a value in a GPR pair (one `LDP`). The SIMD variants split
rows into a lo-word vector and a hi-word vector with structure loads (`LD2`
/ `LD2D`: `LD2X4`, `SVE_LD128`). `LD4 {.4s}` splits them into 32-bit limbs.

* **Comparisons.** In scalar code, `CMP lo; SBCS xzr, hi` leaves the flags
  of the full 128-bit subtraction. `hs`/`lo` give unsigned order and
  `lt`/`ge` give signed order. `Z` only reflects the high word, so the code
  never uses eq/gt/le on such a chain. In vector code, each 128-bit compare
  is three 64-bit lane compares plus one select:
  `(hi <  hi') | (hi == hi' & lo <u lo')`, signed or unsigned on the high
  word. That is `CMGT`/`CMHI`, `CMEQ`, `CMHI`/`CMHS` and `BIT`/`BIF` in
  NEON, and three compares plus predicate `SEL` in SVE.
* **One predicate form.** `filter_i128`/`count_i128` reuse the canonical
  range form of the 64-bit kernels, widened to 128 bits:
  `((x - lo) <=u span) ^ inv`. `PRED128_SETUP` builds `lo`/`span`/`inv`
  from `(op, *a, *b)`. Subtracting or adding 2^127 only flips bit 63 of the
  high word, so `span = a - MIN` and `MAX - lo` need no arithmetic. The
  empty-set cases are detected with the `V` flag of the `SBCS`/`ADCS` that
  forms `a ∓ 1`: LT with `a == INT128_MIN`, GT with `a == INT128_MAX`, and
  BETWEEN with `a > b` (signed flags of `b - a`). `op` is validated before
  `*a` is read, and `*b` is read only for BETWEEN, as the ABI requires.
  `*a` is read even when `n == 0`. In NEON the general range form costs
  8 lane ops per 2 rows (`RNG2`): the borrow is a `CMHI` all-ones mask added
  to the high word, then `CMHS`/`CMHI`/`CMEQ` + `BIF`. `PRED128_FORM` uses
  it only for a genuine BETWEEN. EQ/NE cost 3 ops (`CMEQ`, `CMEQ`, `AND`)
  and LT/LE/GT/GE cost 4 (one signed 128-bit compare: `CMGT`, `CMEQ`,
  `CMHS`, `BIF`).
* **NEON filter_i128** handles 8 rows per iteration. It packs an 8-bit row
  mask (`PACK8`: `UZP1`×3, `AND` with u16 bit weights, `ADDV h`), ANDs it
  with one validity byte, and reuses the `EMIT8` table compaction of
  `filter_i64`. The 32-byte over-store is again bounded by `k <= i` and
  `i + 8 <= n`. `count_i128` subtracts all-ones lane masks into two
  counters. With validity, it applies the inversion per lane with `EOR`.
  Without validity, it applies the inversion once at the end as
  `rows - count`.
* **Exact sum_i128.** The exact sum of `n < 2^32` int128 values has
  magnitude below 2^159, so a **192-bit** two's-complement accumulator
  never wraps and holds the exact mathematical sum. Intermediate
  excursions outside int128 therefore cancel by construction: for example,
  `INT128_MAX, 1, -1` is OK. The result fits in int128 iff the top word
  equals the sign extension of the middle word (`top == mid ASR 63`), and
  this is the only overflow test (`SUM128_RESULT`). On overflow `*out_sum`
  is not written.
  * Scalar: `ADDS`/`ADCS`/`ADC` with the value sign-extended to 192 bits,
    3 additions per row (`ADD192S`).
  * NEON: `LD4 {.4s}` gives one vector per 32-bit limb (lane j = row j).
    `UADALP` accumulates limbs 0–2 and `SADALP` accumulates the signed top
    limb 3 into 64-bit lanes, with two accumulator sets for 8 rows per
    iteration. Invalid rows are zeroed by `AND` with `CMTST` masks. In
    blocks of at most 2^28 rows, every lane stays below 2^58, so it cannot
    wrap even after both sets and both lanes are added. Each block is
    folded into the 192-bit GPR total as
    `L0 + L1·2^32 + L2·2^64 + L3·2^96`, with L3 sign-extended
    (`FOLD_LIMBS192`).
  * SVE: the same limb decomposition (`AND`/`LSR` of the lo word,
    `AND`/`ASR` of the hi word), merging `ADD`s under the valid-row
    predicate, and blocks of 2^24 rows. The block totals are below 2^56,
    so the modular `UADDV` is exact.
  * Why limbs and not a carry count: NEON has no add-with-carry. Splitting
    into 32-bit limbs lets the widening pairwise accumulate instructions do
    the work exactly at about 1 instruction per limb per 4 rows. The
    alternative, `ADD` + `CMHI` carry detection + carry accumulation,
    costs more and still needs a separate signed top word.
* **minmax_i128.**
  * Scalar: `CMP`/`SBCS` + two `CSEL`s per bound. With validity, `CCMP`
    folds "lt and valid" into one condition, so the loop stays branch-free
    (`MIN128V`/`MAX128V`).
  * NEON: lane-wise signed 128-bit compares (12 ops per 2 rows, `MM2`) with
    two independent accumulator sets. Validity is ANDed into the update
    masks. A hi-word window skip test (13 ops per 8 rows) runs those
    updates only for groups that can change a lane. The valid count comes
    from a CNT pass over the validity bytes. The 4 lane candidates are
    folded in GPRs (`REDMM`).
  * SVE: lane-wise compare + `SEL`, then a two-step horizontal reduction:
    `SMINV` of the hi words, then `UMINV` of the lo words over the lanes
    whose hi word equals that minimum. This works because int128 order is
    the lexicographic order of (signed hi, unsigned lo).
  * All variants start from INT128_MAX/INT128_MIN. For integers this is
    indistinguishable from the reference's "first valid value"
    initialisation, and outputs are written only when the count is > 0.
* **Tails and unaligned data.** NEON main loops run only over whole 8-row
  groups, which also makes validity a whole byte per iteration. The 0–7
  remaining rows use the scalar GPR macros. SVE needs no tail: `WHILELO`
  predicates the last vector. `LD2D` is addressed as
  `[x0, 2·row, lsl #3]`, so a block loop can restart at any row. All
  accesses are ordinary loads and stores, so any alignment works.

### SVE specifics
* The file uses `.arch armv8.2-a+sve`, so no Makefile flags are needed. The
  code runs only when the dispatcher sees `HWCAP_SVE`.
* Loops are `WHILELO`/`B.FIRST` with `INCD`/`INCB`, so there are no scalar
  tails. Block loops reset the row counter to the exact block end, because
  with non-power-of-two VLs `INCD` can overshoot a block boundary.
* qemu's default CPU (`max`) reports SVE, so `test-cross` tests all three
  variants, and `a64_sve` becomes the default variant under emulation.

## Decisions taken for CR-5

* **Byte-identical output as the acceptance bar.** CR-5 forbids algorithmic
  changes and asks for no performance regression, which cannot be measured
  here. Keeping the machine code identical makes both properties hold by
  construction and verifiable without hardware. Where a shared macro would
  have needed a different instruction order (e.g. one compare_i64 setup
  macro for all variants), the block was split instead (`CMPOP_CHECK` +
  `CMPOP_SWAP`, with variant code in between), and where a macro would have
  added an instruction (`SVE_LD64` inside `BITMAP_BLOCKS`, whose loop
  already computes the row numbers) it is not used.
* **Three headers instead of one.** Variant-specific blocks (NEON tables,
  SVE predicates) are only meaningful to one variant; keeping them out of
  `pq_a64_common.h` keeps that file about the parts every variant shares.
* **Headers end in `.h`**, are pulled in with `#include` (the files were
  already preprocessed `.S`), and have include guards.
* **The old `pq_a64_macros.h` was removed**; its content is in
  `pq_a64_common.h` (except `MIN128V`/`MAX128V`, which only scalar
  `minmax_i128` uses and which now sit next to it).

## Limitations
* **No performance numbers.** There is no AArch64 hardware, and emulated
  timings are meaningless. Both the design choices and the expected effects
  of the throughput pass come from instruction counts and an assumed
  machine model. The biggest unknown is the single-core DRAM bandwidth of
  the target, which decides whether most streaming kernels can show any
  change at all. The native before/after run decides.
* **Scalar by design in NEON:** `hash_i64` (GPR multiplies), the
  `gather_i64` loads and the `group_sum_i64` scatter-add. A NEON/GPR hybrid
  for `hash_i64` was considered and rejected; the reasons are above.
* **`n < 2^32`.** `filter_i64` and `filter_i128` assume it, as the header
  specifies: indices are formed in 32-bit lanes. `sum_i128` relies on the
  same bound, although the 192-bit accumulator is exact for up to 2^64
  rows anyway and the per-block lane bounds do not depend on `n`.
* **The 128-bit kernels gain less than the 64-bit ones.** A 128-bit
  compare costs 3–4 lane ops plus a select, and a 128-bit register holds
  only two rows. `count_i128` and `filter_i128` with a genuine BETWEEN
  still pay 8 ops per 2 rows.
* **minmax_i128's skip test** is a heuristic for speed, never for the
  result. On input where every 8-row group can change a lane (sorted data,
  constant hi words), it costs about 1–2 % over always running the exact
  update.
* **SVE** has been run only under emulation, and the throughput pass did
  not touch it. `filter_i64_bitmap`/`compare_i64` and the validity gather
  are written for generality across vector lengths, not peak speed on a
  particular core.
* **Verification tools are not in the repository.** The tools used for CR-5
  and for this pass (object comparison, clobber audit, loop instruction
  counter, guard-page and mutation harnesses) are throwaway scripts, like
  the earlier test harnesses. To repeat the CR-5 check: assemble each
  variant at two commits with `aarch64-linux-gnu-gcc -c`, then compare the
  `objcopy -O binary --only-section=.text` (and `.rodata`) outputs and
  `readelf -sW` / `-rW`.
