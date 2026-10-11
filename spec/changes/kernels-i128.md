# Change request CR-4: 128-bit integer kernels (kernel ABI 1, revision 1)

Status: adopted for the *architectural change* experiment family of the native
kernels (x86-64 and AArch64 assembly). Applies identically to both assembly
languages. It is additive: every existing kernel, its semantics and the ABI
version (`pqk_abi_version() == 1`) stay unchanged, so engines built against
revision 0 keep working unmodified.

## 1. Motivation

CR-2 (`decimal38.md`) introduced wide decimals whose unscaled values are
128-bit two's-complement integers (PQCF v2 stores them as i128 little-endian).
CR-2 keeps wide columns away from the native kernels because the ABI had no
128-bit kernels. CR-4 adds them, so that filtering, counting, summation and
min/max over wide decimal columns can be accelerated natively.

## 2. Value representation

```c
typedef struct pqk_i128 { uint64_t lo; int64_t hi; } pqk_i128;
```

The value is `hi · 2⁶⁴ + lo` (signed 128-bit two's complement); in memory this
is exactly the 16-byte little-endian i128 of PQCF v2. Arrays of `pqk_i128` follow
the general ABI rules: pointers may be unaligned (alignment 1), `n` may be 0 and
pointers may then be NULL.

## 3. New kernels

All four use the general rules of `pq_kernels.h` (LSB-first validity bitmaps,
NULL validity = all valid, ascending `uint32_t` selection output, no
allocation, thread-safe after `pqk_init`).

| # | kernel | semantics |
|---|---|---|
| 17 | `size_t pqk_filter_i128(const pqk_i128 *data, const uint8_t *validity, size_t n, int op, const pqk_i128 *a, const pqk_i128 *b, uint32_t *out_idx)` | as `pqk_filter_i64` with signed 128-bit comparison |
| 18 | `size_t pqk_count_i128(const pqk_i128 *data, const uint8_t *validity, size_t n, int op, const pqk_i128 *a, const pqk_i128 *b)` | as `pqk_count_i64` with signed 128-bit comparison |
| 19 | `int pqk_sum_i128(const pqk_i128 *data, const uint8_t *validity, size_t n, pqk_i128 *out_sum)` | exact sum of valid values; `PQK_OVERFLOW` iff the exact final sum is outside the int128 range (intermediate overflow that cancels out is not an error) |
| 20 | `size_t pqk_minmax_i128(const pqk_i128 *data, const uint8_t *validity, size_t n, pqk_i128 *out_min, pqk_i128 *out_max)` | number of valid values; if > 0 writes min and max |

Operator rules (filter, count): `op` is one of `PQK_EQ … PQK_BETWEEN`; any
other value returns `(size_t)-1` and dereferences neither `a` nor `b`. `a` is
always dereferenced for a valid `op` (it must point to a value even when
`n == 0`); `b` is dereferenced only for `PQK_BETWEEN` and may be NULL
otherwise. `a`/`b` may alias elements of `data`.

Exact summation: `n < 2³²`, so the exact sum needs at most 160 bits; an
implementation must not report overflow for sums that come back into range
(e.g. `INT128_MAX, 1, -1` is `PQK_OK`) and must report it for every final sum
outside `[-2¹²⁷, 2¹²⁷-1]`. `*out_sum` is meaningful only for `PQK_OK`.

Decimal-range checks (|unscaled| ≤ 10³⁸ − 1) are the engine's job, not the
kernel's: the kernels operate on the full int128 domain.

## 4. ABI revision

* `PQK_ABI_REVISION` (header macro) and `int pqk_abi_revision(void)` return 1.
  Revision 0 is the original 16-kernel ABI; `pqk_abi_version()` stays 1.
* Variant discovery is unchanged (weak symbols `pqk_<variant>_<kernel>`); a
  variant that does not define a 128-bit kernel falls back to the C reference,
  so a library built from revision-0 assembly is still complete and correct.

## 5. Acceptance (assembly experiment family)

For each assembly language, the required variants (`x86_scalar` and
`x86_avx2`, or `a64_scalar` and `a64_neon`) provide all 20 kernels and pass
the differential tests (`make -C native-kernels test`, which reports
`20/20 kernels  PASS` per variant) natively and under AddressSanitizer/UBSan;
AArch64 additionally passes natively on the ARM host and, for an `a64_sve`
variant, under emulated vector lengths 128–2048 bits. Optional variants
(`x86_avx512`, `a64_sve`) that are built must pass as well.
