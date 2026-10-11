/*
 * PolyQuery native kernels — portable C17 reference implementation.
 * Normative semantics for all variants (see include/pq_kernels.h).
 */
#include "pq_kernels_internal.h"

#include <string.h>

static inline int valid_at(const uint8_t *validity, size_t i) {
    return validity == NULL || ((validity[i >> 3] >> (i & 7)) & 1);
}

static inline int pred(int op, int64_t x, int64_t a, int64_t b) {
    switch (op) {
    case PQK_EQ: return x == a;
    case PQK_NE: return x != a;
    case PQK_LT: return x < a;
    case PQK_LE: return x <= a;
    case PQK_GT: return x > a;
    case PQK_GE: return x >= a;
    case PQK_BETWEEN: return a <= x && x <= b;
    default: return 0;
    }
}

size_t pqk_ref_filter_i64(const int64_t *data, const uint8_t *validity, size_t n,
                          int op, int64_t a, int64_t b, uint32_t *out_idx) {
    if (op < PQK_EQ || op > PQK_BETWEEN) return (size_t)-1;
    size_t k = 0;
    for (size_t i = 0; i < n; i++) {
        int64_t x;
        memcpy(&x, data + i, sizeof x);
        if (valid_at(validity, i) && pred(op, x, a, b)) out_idx[k++] = (uint32_t)i;
    }
    return k;
}

size_t pqk_ref_filter_i64_bitmap(const int64_t *data, const uint8_t *validity, size_t n,
                                 int op, int64_t a, int64_t b, uint8_t *out_bits) {
    if (op < PQK_EQ || op > PQK_BETWEEN) return (size_t)-1;
    size_t nb = (n + 7) / 8, k = 0;
    memset(out_bits, 0, nb);
    for (size_t i = 0; i < n; i++) {
        int64_t x;
        memcpy(&x, data + i, sizeof x);
        if (valid_at(validity, i) && pred(op, x, a, b)) {
            out_bits[i >> 3] |= (uint8_t)(1u << (i & 7));
            k++;
        }
    }
    return k;
}

int pqk_ref_sum_i64(const int64_t *data, const uint8_t *validity, size_t n, int64_t *out_sum) {
    /* Exact 128-bit accumulation: only the final value must fit in int64. */
    __int128 acc = 0;
    for (size_t i = 0; i < n; i++) {
        int64_t x;
        memcpy(&x, data + i, sizeof x);
        if (valid_at(validity, i)) acc += x;
    }
    if (acc > INT64_MAX || acc < INT64_MIN) return PQK_OVERFLOW;
    *out_sum = (int64_t)acc;
    return PQK_OK;
}

double pqk_ref_sum_f64(const double *data, const uint8_t *validity, size_t n) {
    double s = 0.0;
    for (size_t i = 0; i < n; i++) {
        double x;
        memcpy(&x, data + i, sizeof x);
        if (valid_at(validity, i)) s += x;
    }
    return s;
}

size_t pqk_ref_minmax_i64(const int64_t *data, const uint8_t *validity, size_t n,
                          int64_t *out_min, int64_t *out_max) {
    size_t cnt = 0;
    int64_t lo = INT64_MAX, hi = INT64_MIN;
    for (size_t i = 0; i < n; i++) {
        int64_t x;
        memcpy(&x, data + i, sizeof x);
        if (!valid_at(validity, i)) continue;
        if (x < lo) lo = x;
        if (x > hi) hi = x;
        cnt++;
    }
    if (cnt) { *out_min = lo; *out_max = hi; }
    return cnt;
}

size_t pqk_ref_minmax_f64(const double *data, const uint8_t *validity, size_t n,
                          double *out_min, double *out_max) {
    size_t cnt = 0;
    double lo = 0, hi = 0;
    for (size_t i = 0; i < n; i++) {
        double x;
        memcpy(&x, data + i, sizeof x);
        if (!valid_at(validity, i)) continue;
        if (cnt == 0 || x < lo) lo = x;
        if (cnt == 0 || x > hi) hi = x;
        cnt++;
    }
    if (cnt) { *out_min = lo; *out_max = hi; }
    return cnt;
}

size_t pqk_ref_count_i64(const int64_t *data, const uint8_t *validity, size_t n, int op, int64_t a, int64_t b) {
    if (op < PQK_EQ || op > PQK_BETWEEN) return (size_t)-1;
    size_t k = 0;
    for (size_t i = 0; i < n; i++) {
        int64_t x;
        memcpy(&x, data + i, sizeof x);
        k += valid_at(validity, i) && pred(op, x, a, b);
    }
    return k;
}

void pqk_ref_bitmap_and(const uint8_t *a, const uint8_t *b, uint8_t *out, size_t nbytes) {
    for (size_t i = 0; i < nbytes; i++) out[i] = a[i] & b[i];
}

void pqk_ref_bitmap_or(const uint8_t *a, const uint8_t *b, uint8_t *out, size_t nbytes) {
    for (size_t i = 0; i < nbytes; i++) out[i] = a[i] | b[i];
}

void pqk_ref_bitmap_andnot(const uint8_t *a, const uint8_t *b, uint8_t *out, size_t nbytes) {
    for (size_t i = 0; i < nbytes; i++) out[i] = a[i] & (uint8_t)~b[i];
}

size_t pqk_ref_bitmap_popcount(const uint8_t *bits, size_t nbits) {
    size_t c = 0, full = nbits / 8;
    for (size_t i = 0; i < full; i++) c += (size_t)__builtin_popcount(bits[i]);
    if (nbits & 7) c += (size_t)__builtin_popcount(bits[full] & ((1u << (nbits & 7)) - 1));
    return c;
}

static inline uint64_t fmix64(uint64_t k) {
    k ^= k >> 33;
    k *= 0xff51afd7ed558ccdULL;
    k ^= k >> 33;
    k *= 0xc4ceb9fe1a85ec53ULL;
    k ^= k >> 33;
    return k;
}

void pqk_ref_hash_i64(const int64_t *data, size_t n, uint64_t seed, uint64_t *out) {
    for (size_t i = 0; i < n; i++) {
        int64_t x;
        memcpy(&x, data + i, sizeof x);
        uint64_t h = fmix64((uint64_t)x ^ seed);
        memcpy(out + i, &h, sizeof h);
    }
}

size_t pqk_ref_compare_i64(const int64_t *a, const int64_t *b, size_t n, int op, uint8_t *out_bits) {
    if (op < PQK_EQ || op > PQK_GE) return (size_t)-1;
    size_t nb = (n + 7) / 8, k = 0;
    memset(out_bits, 0, nb);
    for (size_t i = 0; i < n; i++) {
        int64_t x, y;
        memcpy(&x, a + i, sizeof x);
        memcpy(&y, b + i, sizeof y);
        if (pred(op, x, y, 0)) {
            out_bits[i >> 3] |= (uint8_t)(1u << (i & 7));
            k++;
        }
    }
    return k;
}

void pqk_ref_compare_fixed(const uint8_t *a, const uint8_t *b, size_t width, size_t n, int8_t *out) {
    for (size_t i = 0; i < n; i++) {
        int c = width ? memcmp(a + i * width, b + i * width, width) : 0;
        out[i] = (int8_t)((c > 0) - (c < 0));
    }
}

int pqk_ref_group_sum_i64(const uint32_t *group_ids, const int64_t *values, const uint8_t *validity,
                          size_t n, int64_t *sums, int64_t *counts, size_t ngroups) {
    for (size_t i = 0; i < n; i++)
        if (valid_at(validity, i) && group_ids[i] >= ngroups) return PQK_EINVAL;
    int wrapped = 0;
    for (size_t i = 0; i < n; i++) {
        if (!valid_at(validity, i)) continue;
        uint32_t g = group_ids[i];
        int64_t x;
        memcpy(&x, values + i, sizeof x);
        wrapped |= __builtin_add_overflow(sums[g], x, &sums[g]);
        if (counts) counts[g] += 1;
    }
    return wrapped ? PQK_OVERFLOW : PQK_OK;
}

void pqk_ref_gather_i64(const int64_t *data, const uint32_t *idx, size_t m, int64_t *out) {
    for (size_t j = 0; j < m; j++) memcpy(out + j, data + idx[j], sizeof(int64_t));
}

/* ---- 128-bit kernels (CR-4) ------------------------------------------- */

static inline __int128 load_i128(const pqk_i128 *p) {
    pqk_i128 v;
    memcpy(&v, p, sizeof v);
    return (__int128)(((unsigned __int128)(uint64_t)v.hi << 64) | v.lo);
}

static inline void store_i128(pqk_i128 *p, __int128 x) {
    pqk_i128 v = {(uint64_t)x, (int64_t)(x >> 64)};
    memcpy(p, &v, sizeof v);
}

static inline int pred128(int op, __int128 x, __int128 a, __int128 b) {
    switch (op) {
    case PQK_EQ: return x == a;
    case PQK_NE: return x != a;
    case PQK_LT: return x < a;
    case PQK_LE: return x <= a;
    case PQK_GT: return x > a;
    case PQK_GE: return x >= a;
    case PQK_BETWEEN: return a <= x && x <= b;
    default: return 0;
    }
}

size_t pqk_ref_filter_i128(const pqk_i128 *data, const uint8_t *validity, size_t n,
                           int op, const pqk_i128 *a, const pqk_i128 *b, uint32_t *out_idx) {
    if (op < PQK_EQ || op > PQK_BETWEEN) return (size_t)-1;
    __int128 av = load_i128(a), bv = op == PQK_BETWEEN ? load_i128(b) : 0;
    size_t k = 0;
    for (size_t i = 0; i < n; i++)
        if (valid_at(validity, i) && pred128(op, load_i128(data + i), av, bv)) out_idx[k++] = (uint32_t)i;
    return k;
}

size_t pqk_ref_count_i128(const pqk_i128 *data, const uint8_t *validity, size_t n,
                          int op, const pqk_i128 *a, const pqk_i128 *b) {
    if (op < PQK_EQ || op > PQK_BETWEEN) return (size_t)-1;
    __int128 av = load_i128(a), bv = op == PQK_BETWEEN ? load_i128(b) : 0;
    size_t k = 0;
    for (size_t i = 0; i < n; i++)
        k += valid_at(validity, i) && pred128(op, load_i128(data + i), av, bv);
    return k;
}

int pqk_ref_sum_i128(const pqk_i128 *data, const uint8_t *validity, size_t n, pqk_i128 *out_sum) {
    /* Exact sum = acc + wraps * 2^128; it is representable iff wraps == 0. */
    __int128 acc = 0;
    long long wraps = 0;
    for (size_t i = 0; i < n; i++) {
        if (!valid_at(validity, i)) continue;
        __int128 x = load_i128(data + i);
        if (__builtin_add_overflow(acc, x, &acc)) wraps += x > 0 ? 1 : -1;
    }
    if (wraps) return PQK_OVERFLOW;
    store_i128(out_sum, acc);
    return PQK_OK;
}

size_t pqk_ref_minmax_i128(const pqk_i128 *data, const uint8_t *validity, size_t n,
                           pqk_i128 *out_min, pqk_i128 *out_max) {
    size_t k = 0;
    __int128 lo = 0, hi = 0;
    for (size_t i = 0; i < n; i++) {
        if (!valid_at(validity, i)) continue;
        __int128 x = load_i128(data + i);
        if (k == 0 || x < lo) lo = x;
        if (k == 0 || x > hi) hi = x;
        k++;
    }
    if (k) {
        store_i128(out_min, lo);
        store_i128(out_max, hi);
    }
    return k;
}
