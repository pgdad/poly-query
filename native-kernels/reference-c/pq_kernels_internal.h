/* Internal declarations shared by the reference implementation, the dispatcher
 * and the tests. Not part of the public ABI. */
#ifndef PQ_KERNELS_INTERNAL_H
#define PQ_KERNELS_INTERNAL_H
#include "pq_kernels.h"

/* X-macro over all kernels: X(name, return type, parameter list, argument list) */
#define PQK_KERNELS(X) \
  X(filter_i64, size_t, (const int64_t *data, const uint8_t *validity, size_t n, int op, int64_t a, int64_t b, uint32_t *out_idx), (data, validity, n, op, a, b, out_idx)) \
  X(filter_i64_bitmap, size_t, (const int64_t *data, const uint8_t *validity, size_t n, int op, int64_t a, int64_t b, uint8_t *out_bits), (data, validity, n, op, a, b, out_bits)) \
  X(sum_i64, int, (const int64_t *data, const uint8_t *validity, size_t n, int64_t *out_sum), (data, validity, n, out_sum)) \
  X(sum_f64, double, (const double *data, const uint8_t *validity, size_t n), (data, validity, n)) \
  X(minmax_i64, size_t, (const int64_t *data, const uint8_t *validity, size_t n, int64_t *out_min, int64_t *out_max), (data, validity, n, out_min, out_max)) \
  X(minmax_f64, size_t, (const double *data, const uint8_t *validity, size_t n, double *out_min, double *out_max), (data, validity, n, out_min, out_max)) \
  X(count_i64, size_t, (const int64_t *data, const uint8_t *validity, size_t n, int op, int64_t a, int64_t b), (data, validity, n, op, a, b)) \
  X(bitmap_and, void, (const uint8_t *a, const uint8_t *b, uint8_t *out, size_t nbytes), (a, b, out, nbytes)) \
  X(bitmap_or, void, (const uint8_t *a, const uint8_t *b, uint8_t *out, size_t nbytes), (a, b, out, nbytes)) \
  X(bitmap_andnot, void, (const uint8_t *a, const uint8_t *b, uint8_t *out, size_t nbytes), (a, b, out, nbytes)) \
  X(bitmap_popcount, size_t, (const uint8_t *bits, size_t nbits), (bits, nbits)) \
  X(hash_i64, void, (const int64_t *data, size_t n, uint64_t seed, uint64_t *out), (data, n, seed, out)) \
  X(compare_i64, size_t, (const int64_t *a, const int64_t *b, size_t n, int op, uint8_t *out_bits), (a, b, n, op, out_bits)) \
  X(compare_fixed, void, (const uint8_t *a, const uint8_t *b, size_t width, size_t n, int8_t *out), (a, b, width, n, out)) \
  X(group_sum_i64, int, (const uint32_t *group_ids, const int64_t *values, const uint8_t *validity, size_t n, int64_t *sums, int64_t *counts, size_t ngroups), (group_ids, values, validity, n, sums, counts, ngroups)) \
  X(gather_i64, void, (const int64_t *data, const uint32_t *idx, size_t m, int64_t *out), (data, idx, m, out)) \
  X(filter_i128, size_t, (const pqk_i128 *data, const uint8_t *validity, size_t n, int op, const pqk_i128 *a, const pqk_i128 *b, uint32_t *out_idx), (data, validity, n, op, a, b, out_idx)) \
  X(count_i128, size_t, (const pqk_i128 *data, const uint8_t *validity, size_t n, int op, const pqk_i128 *a, const pqk_i128 *b), (data, validity, n, op, a, b)) \
  X(sum_i128, int, (const pqk_i128 *data, const uint8_t *validity, size_t n, pqk_i128 *out_sum), (data, validity, n, out_sum)) \
  X(minmax_i128, size_t, (const pqk_i128 *data, const uint8_t *validity, size_t n, pqk_i128 *out_min, pqk_i128 *out_max), (data, validity, n, out_min, out_max))

/* Number of kernels in the ABI (revision 1). */
#define PQK_NKERNELS 20

#define PQK_DECL_REF(name, ret, params, args) ret pqk_ref_##name params;
PQK_KERNELS(PQK_DECL_REF)

typedef struct pqk_table {
#define PQK_FIELD(name, ret, params, args) ret (*name) params;
  PQK_KERNELS(PQK_FIELD)
} pqk_table;

/* Variant names in preference order (best first). */
#define PQK_VARIANTS(V) V(x86_avx512) V(x86_avx2) V(x86_scalar) V(a64_sve) V(a64_neon) V(a64_scalar)

/* Fills *t with the given variant's functions; functions a variant does not
 * implement fall back to the reference. Returns the number of functions the
 * variant itself provides (0 = variant not built). */
int pqk_variant_table(const char *variant, pqk_table *t);
int pqk_cpu_supports(const char *variant);
#endif
