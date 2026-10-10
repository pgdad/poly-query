/*
 * PolyQuery native kernels — stable C ABI, version 1.
 *
 * Normative semantics for every variant (reference C, x86-64 scalar/AVX2/AVX-512,
 * AArch64 scalar/NEON/SVE). All variants MUST produce bit-identical results for
 * integer kernels. Float kernels are documented individually.
 *
 * General rules:
 *   - Pointers may be unaligned. n may be 0 (pointers may then be NULL).
 *   - Input and output buffers never overlap unless stated.
 *   - Validity bitmaps are LSB-first (row i = bit i%8 of byte i/8), 1 = non-null.
 *     A NULL validity pointer means "all rows valid".
 *   - Selection outputs are ascending row indices (uint32_t); n < 2^32.
 *   - Functions are thread-safe after pqk_init() and do not allocate.
 */
#ifndef PQ_KERNELS_H
#define PQ_KERNELS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PQK_ABI_VERSION 1

/* Status codes */
#define PQK_OK        0
#define PQK_OVERFLOW  1  /* signed 64-bit overflow of the exact mathematical result */
#define PQK_EINVAL    2  /* invalid argument (e.g. unknown op) */

/* Comparison operators: predicate on value x with constants a, b */
#define PQK_EQ       0   /* x == a        */
#define PQK_NE       1   /* x != a        */
#define PQK_LT       2   /* x <  a        */
#define PQK_LE       3   /* x <= a        */
#define PQK_GT       4   /* x >  a        */
#define PQK_GE       5   /* x >= a        */
#define PQK_BETWEEN  6   /* a <= x <= b   */

/* ---- Library / dispatch ---------------------------------------------- */

/* Returns PQK_ABI_VERSION. */
int pqk_abi_version(void);

/* Detects CPU features and selects variants. Honors env PQ_KERNELS_VARIANT
 * ("reference","scalar","avx2","avx512","neon","sve"); an unavailable requested
 * variant falls back to the best available one. Idempotent. Returns PQK_OK. */
int pqk_init(void);

/* Forces a variant; returns PQK_EINVAL if unsupported on this CPU/build. */
int pqk_set_variant(const char *name);

/* Name of the active variant (static string). */
const char *pqk_variant(void);

/* Comma-separated list of variants usable on this CPU (static string). */
const char *pqk_available_variants(void);

/* ---- 1. Integer filtering ---------------------------------------------- */

/* Writes indices i (ascending) where op(data[i], a, b) holds and (validity==NULL
 * or row i valid) into out_idx (capacity >= n). Returns the count, or
 * (size_t)-1 for an unknown op. */
size_t pqk_filter_i64(const int64_t *data, const uint8_t *validity, size_t n,
                      int op, int64_t a, int64_t b, uint32_t *out_idx);

/* Same predicate, result as a bitmap out_bits (ceil(n/8) bytes, trailing bits
 * zeroed). Returns the number of set bits, or (size_t)-1 for an unknown op. */
size_t pqk_filter_i64_bitmap(const int64_t *data, const uint8_t *validity, size_t n,
                             int op, int64_t a, int64_t b, uint8_t *out_bits);

/* ---- 2. Integer summation ---------------------------------------------- */

/* Sums valid values exactly. *out_sum receives the sum (only meaningful when
 * PQK_OK). Returns PQK_OVERFLOW if the exact final sum is outside int64 range
 * (intermediate overflow that cancels out is NOT an error). */
int pqk_sum_i64(const int64_t *data, const uint8_t *validity, size_t n, int64_t *out_sum);

/* Sum of valid doubles. Result may differ from sequential summation by
 * reassociation (lane-wise partial sums); |error| <= n * eps * sum(|x_i|). */
double pqk_sum_f64(const double *data, const uint8_t *validity, size_t n);

/* ---- 3. Minimum and maximum -------------------------------------------- */

/* Returns the number of valid values; if > 0 writes *out_min / *out_max. */
size_t pqk_minmax_i64(const int64_t *data, const uint8_t *validity, size_t n,
                      int64_t *out_min, int64_t *out_max);

/* Same for finite doubles (inputs contain no NaN). */
size_t pqk_minmax_f64(const double *data, const uint8_t *validity, size_t n,
                      double *out_min, double *out_max);

/* ---- 4. Predicate counting --------------------------------------------- */

/* Number of valid rows satisfying the predicate; (size_t)-1 for unknown op. */
size_t pqk_count_i64(const int64_t *data, const uint8_t *validity, size_t n,
                     int op, int64_t a, int64_t b);

/* ---- 5. Bitmap operations ---------------------------------------------- */

/* out[i] = a[i] & b[i] / a[i] | b[i] / a[i] & ~b[i] for i < nbytes.
 * out may alias a or b. */
void pqk_bitmap_and(const uint8_t *a, const uint8_t *b, uint8_t *out, size_t nbytes);
void pqk_bitmap_or(const uint8_t *a, const uint8_t *b, uint8_t *out, size_t nbytes);
void pqk_bitmap_andnot(const uint8_t *a, const uint8_t *b, uint8_t *out, size_t nbytes);

/* Number of set bits among the first nbits bits. */
size_t pqk_bitmap_popcount(const uint8_t *bits, size_t nbits);

/* ---- 6. Hashing --------------------------------------------------------- */

/* out[i] = fmix64((uint64_t)data[i] ^ seed), where fmix64 is the MurmurHash3
 * 64-bit finalizer:
 *   k ^= k >> 33; k *= 0xff51afd7ed558ccd; k ^= k >> 33;
 *   k *= 0xc4ceb9fe1a85ec53; k ^= k >> 33;
 * (multiplications modulo 2^64). Validity is not consulted. */
void pqk_hash_i64(const int64_t *data, size_t n, uint64_t seed, uint64_t *out);

/* ---- 7. Fixed-width value comparison ----------------------------------- */

/* Element-wise comparison of two int64 columns: bit i of out_bits is
 * op(a[i], b[i]) (PQK_EQ..PQK_GE; BETWEEN is invalid). Validity is not
 * consulted. Returns number of set bits or (size_t)-1 for an invalid op. */
size_t pqk_compare_i64(const int64_t *a, const int64_t *b, size_t n, int op, uint8_t *out_bits);

/* Lexicographic unsigned-byte comparison of n records of `width` bytes each:
 * out[i] = -1, 0, 1 for a_i <, ==, > b_i. */
void pqk_compare_fixed(const uint8_t *a, const uint8_t *b, size_t width, size_t n, int8_t *out);

/* ---- 8. Vectorized aggregation primitives ------------------------------ */

/* For valid rows i: sums[group_ids[i]] += values[i], counts[group_ids[i]] += 1.
 * sums/counts (length ngroups) are accumulated into (not zeroed). Returns
 * PQK_EINVAL if some valid row has group_ids[i] >= ngroups (no partial
 * guarantee on outputs), PQK_OVERFLOW if any final group sum overflows
 * int64 (outputs then unspecified), else PQK_OK. counts may be NULL. */
int pqk_group_sum_i64(const uint32_t *group_ids, const int64_t *values, const uint8_t *validity,
                      size_t n, int64_t *sums, int64_t *counts, size_t ngroups);

/* Gathers values by selection vector: out[j] = data[idx[j]] for j < m. */
void pqk_gather_i64(const int64_t *data, const uint32_t *idx, size_t m, int64_t *out);

#ifdef __cplusplus
}
#endif
#endif /* PQ_KERNELS_H */
