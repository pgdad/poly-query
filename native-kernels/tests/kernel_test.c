/*
 * Randomized differential tests: every built variant vs. the C reference.
 * Covers empty inputs, unaligned pointers, tails, extreme values, NULL
 * validity, all predicate ops, overflow semantics and known-answer vectors.
 *
 * Usage: kernel_test [iterations] [seed]
 */
#include "pq_kernels_internal.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t rs = 0x9E3779B97F4A7C15ULL;
static uint64_t rnd(void) { /* splitmix64 */
  uint64_t z = (rs += 0x9E3779B97F4A7C15ULL);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  return z ^ (z >> 31);
}
static size_t rnd_below(size_t n) { return n ? (size_t)(rnd() % n) : 0; }

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; if (failures < 40) { \
  fprintf(stderr, "FAIL [%s] %s:%d: ", vname, __func__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } } while (0)

static int64_t rand_i64(int mode) {
  switch (mode) {
  case 0: return (int64_t)rnd_below(100) - 50;                       /* small, many duplicates */
  case 1: return (int64_t)rnd();                                      /* full range */
  case 2: { int64_t ex[] = {INT64_MIN, INT64_MIN + 1, -1, 0, 1, INT64_MAX - 1, INT64_MAX};
            return ex[rnd_below(7)]; }
  default: return (int64_t)(rnd() >> (rnd_below(60) + 2)) * ((rnd() & 1) ? 1 : -1);
  }
}

static __int128 rand_i128(int mode) {
  const __int128 MAX = (__int128)(((unsigned __int128)1 << 127) - 1), MIN = -MAX - 1;
  const __int128 D38 = (__int128)10000000000000000000ULL * (__int128)10000000000000000000ULL - 1; /* 10^38 - 1 */
  switch (mode) {
  case 0: return (__int128)((int64_t)rnd_below(100) - 50);                          /* small, many duplicates */
  case 1: return (__int128)(((unsigned __int128)rnd() << 64) | rnd());               /* full range */
  case 2: { __int128 ex[] = {MIN, MIN + 1, -1, 0, 1, MAX - 1, MAX, D38, -D38, (__int128)INT64_MAX + 1,
                             (__int128)INT64_MIN - 1, (__int128)1 << 64, -((__int128)1 << 64), (__int128)UINT64_MAX};
            return ex[rnd_below(sizeof ex / sizeof ex[0])]; }
  case 3: { /* hi in {-1, 0, 1}: exercises the signed-high / unsigned-low limb comparison */
            int64_t hi = (int64_t)rnd_below(3) - 1;
            return (__int128)(((unsigned __int128)(uint64_t)hi << 64) | rnd()); }
  default: { /* decimal-like: |x| < 10^38, varying magnitude */
            __int128 x = (__int128)(((unsigned __int128)(rnd() >> 1) << 64) | rnd()) >> rnd_below(126);
            x %= D38 + 1;
            return (rnd() & 1) ? x : -x; }
  }
}
static pqk_i128 to_s(__int128 x) { pqk_i128 v = {(uint64_t)x, (int64_t)(x >> 64)}; return v; }
static __int128 from_s(pqk_i128 v) { return (__int128)(((unsigned __int128)(uint64_t)v.hi << 64) | v.lo); }
static __int128 load_u(const pqk_i128 *p) { pqk_i128 v; memcpy(&v, p, sizeof v); return from_s(v); }  /* unaligned */
static int64_t load64_u(const int64_t *p) { int64_t v; memcpy(&v, p, sizeof v); return v; }

/* Unaligned buffers: allocate with slack and offset by 0..7 bytes. */
typedef struct { unsigned char *base; void *p; } ubuf;
static ubuf ualloc(size_t bytes, size_t off) {
  ubuf b;
  b.base = malloc(bytes + 16);
  b.p = b.base + off;
  memset(b.base, 0xA5, bytes + 16);
  return b;
}

static void test_variant(const char *vname, const pqk_table *v, const pqk_table *r, int iters) {
  for (int it = 0; it < iters; it++) {
    size_t n = (it % 10 == 0) ? rnd_below(5000) : rnd_below(300);
    if (it % 97 == 0) n = 0;
    size_t off = rnd_below(8);
    int mode = (int)rnd_below(4);
    ubuf d = ualloc(n * 8 + 8, off), d2 = ualloc(n * 8 + 8, rnd_below(8));
    int64_t *data = d.p, *data2 = d2.p;
    for (size_t i = 0; i < n; i++) {
      int64_t x = rand_i64(mode), y = (rnd() & 3) ? x : rand_i64(mode);
      memcpy(data + i, &x, 8);
      memcpy(data2 + i, &y, 8);
    }
    size_t nb = (n + 7) / 8;
    uint8_t *validity = NULL;
    ubuf vb = ualloc(nb + 1, rnd_below(4));
    if (rnd() & 1) {
      validity = vb.p;
      for (size_t i = 0; i < nb; i++) validity[i] = (uint8_t)rnd();
    }
    int op = (int)rnd_below(7);
    int64_t a = rnd() & 1 ? rand_i64(mode) : (n ? load64_u(data + rnd_below(n)) : 0), b = rand_i64(mode);
    if (op == PQK_BETWEEN && a > b) { int64_t t = a; a = b; b = t; }

    /* filter (index) */
    uint32_t *i1 = calloc(n + 1, 4), *i2 = calloc(n + 1, 4);
    size_t c1 = r->filter_i64(data, validity, n, op, a, b, i1);
    size_t c2 = v->filter_i64(data, validity, n, op, a, b, i2);
    CHECK(c1 == c2 && !memcmp(i1, i2, c1 * 4), "filter_i64 n=%zu op=%d off=%zu: %zu vs %zu", n, op, off, c1, c2);
    /* filter (bitmap) */
    uint8_t *b1 = calloc(nb + 1, 1), *b2 = calloc(nb + 1, 1);
    c1 = r->filter_i64_bitmap(data, validity, n, op, a, b, b1);
    c2 = v->filter_i64_bitmap(data, validity, n, op, a, b, b2);
    CHECK(c1 == c2 && !memcmp(b1, b2, nb), "filter_i64_bitmap n=%zu op=%d", n, op);
    /* invalid op */
    CHECK(v->filter_i64(data, validity, n, 99, a, b, i2) == (size_t)-1, "filter_i64 invalid op");
    CHECK(v->count_i64(data, validity, n, -1, a, b) == (size_t)-1, "count_i64 invalid op");
    /* count */
    CHECK(r->count_i64(data, validity, n, op, a, b) == v->count_i64(data, validity, n, op, a, b), "count_i64 n=%zu op=%d", n, op);
    /* sum */
    int64_t s1 = 0x1234, s2 = 0x1234;
    int r1 = r->sum_i64(data, validity, n, &s1), r2 = v->sum_i64(data, validity, n, &s2);
    CHECK(r1 == r2 && (r1 != PQK_OK || s1 == s2), "sum_i64 n=%zu mode=%d: %d/%lld vs %d/%lld", n, mode, r1, (long long)s1, r2, (long long)s2);
    /* minmax */
    int64_t lo1 = 7, hi1 = 7, lo2 = 7, hi2 = 7;
    c1 = r->minmax_i64(data, validity, n, &lo1, &hi1);
    c2 = v->minmax_i64(data, validity, n, &lo2, &hi2);
    CHECK(c1 == c2 && (!c1 || (lo1 == lo2 && hi1 == hi2)), "minmax_i64 n=%zu", n);
    /* doubles */
    ubuf fb = ualloc(n * 8 + 8, rnd_below(8));
    double *f = fb.p, sabs = 0;
    for (size_t i = 0; i < n; i++) {
      double x = ((double)(int64_t)(rnd() >> 11) / 9007199254740992.0) * (double)(1 << rnd_below(30)) * ((rnd() & 1) ? 1 : -1);
      memcpy(f + i, &x, 8);
      if (!validity || (validity[i >> 3] >> (i & 7) & 1)) sabs += fabs(x);
    }
    double fs1 = r->sum_f64(f, validity, n), fs2 = v->sum_f64(f, validity, n);
    CHECK(fabs(fs1 - fs2) <= (double)(n + 1) * 2.3e-16 * sabs + 1e-300, "sum_f64 n=%zu %.17g vs %.17g", n, fs1, fs2);
    double flo1 = 0, fhi1 = 0, flo2 = 0, fhi2 = 0;
    c1 = r->minmax_f64(f, validity, n, &flo1, &fhi1);
    c2 = v->minmax_f64(f, validity, n, &flo2, &fhi2);
    CHECK(c1 == c2 && (!c1 || (flo1 == flo2 && fhi1 == fhi2)), "minmax_f64 n=%zu", n);
    /* bitmaps */
    size_t nbytes = rnd_below(200);
    ubuf ba = ualloc(nbytes + 1, rnd_below(8)), bb = ualloc(nbytes + 1, rnd_below(8));
    uint8_t *x = ba.p, *y = bb.p, *o1 = malloc(nbytes + 1), *o2 = malloc(nbytes + 1);
    for (size_t i = 0; i < nbytes; i++) { x[i] = (uint8_t)rnd(); y[i] = (uint8_t)rnd(); }
    r->bitmap_and(x, y, o1, nbytes); v->bitmap_and(x, y, o2, nbytes);
    CHECK(!memcmp(o1, o2, nbytes), "bitmap_and %zu", nbytes);
    r->bitmap_or(x, y, o1, nbytes); v->bitmap_or(x, y, o2, nbytes);
    CHECK(!memcmp(o1, o2, nbytes), "bitmap_or %zu", nbytes);
    r->bitmap_andnot(x, y, o1, nbytes); v->bitmap_andnot(x, y, o2, nbytes);
    CHECK(!memcmp(o1, o2, nbytes), "bitmap_andnot %zu", nbytes);
    memcpy(o2, x, nbytes); v->bitmap_and(o2, y, o2, nbytes);      /* aliasing */
    r->bitmap_and(x, y, o1, nbytes);
    CHECK(!memcmp(o1, o2, nbytes), "bitmap_and aliasing");
    size_t nbits = nbytes * 8 - (nbytes ? rnd_below(8) : 0);
    CHECK(r->bitmap_popcount(x, nbits) == v->bitmap_popcount(x, nbits), "bitmap_popcount nbits=%zu", nbits);
    /* hash */
    uint64_t seed = rnd();
    uint64_t *h1 = calloc(n + 1, 8), *h2 = calloc(n + 1, 8);
    r->hash_i64(data, n, seed, h1); v->hash_i64(data, n, seed, h2);
    CHECK(!memcmp(h1, h2, n * 8), "hash_i64 n=%zu", n);
    /* compare_i64 */
    int cop = (int)rnd_below(6);
    c1 = r->compare_i64(data, data2, n, cop, b1);
    c2 = v->compare_i64(data, data2, n, cop, b2);
    CHECK(c1 == c2 && !memcmp(b1, b2, nb), "compare_i64 n=%zu op=%d", n, cop);
    CHECK(v->compare_i64(data, data2, n, PQK_BETWEEN, b2) == (size_t)-1, "compare_i64 BETWEEN must be invalid");
    /* compare_fixed */
    size_t width = rnd_below(34), m = rnd_below(64);
    unsigned char *fa = malloc(width * m + 1), *fbx = malloc(width * m + 1);
    for (size_t i = 0; i < width * m; i++) { fa[i] = (unsigned char)rnd_below(4); fbx[i] = (rnd() & 7) ? fa[i] : (unsigned char)rnd(); }
    int8_t *co1 = malloc(m + 1), *co2 = malloc(m + 1);
    r->compare_fixed(fa, fbx, width, m, co1); v->compare_fixed(fa, fbx, width, m, co2);
    CHECK(!memcmp(co1, co2, m), "compare_fixed width=%zu m=%zu", width, m);
    /* group sums */
    size_t ng = 1 + rnd_below(50);
    uint32_t *gid = malloc((n + 1) * 4);
    for (size_t i = 0; i < n; i++) gid[i] = (uint32_t)rnd_below(ng);
    int64_t *gs1 = calloc(ng, 8), *gs2 = calloc(ng, 8), *gc1 = calloc(ng, 8), *gc2 = calloc(ng, 8);
    r1 = r->group_sum_i64(gid, data, validity, n, gs1, gc1, ng);
    r2 = v->group_sum_i64(gid, data, validity, n, gs2, gc2, ng);
    CHECK(r2 != PQK_EINVAL, "group_sum_i64 spurious EINVAL");
    if (r1 == PQK_OK) CHECK(r2 == PQK_OK || mode == 1 || mode == 2, "group_sum_i64 spurious overflow");
    if (r2 == PQK_OK) CHECK(!memcmp(gs1, gs2, ng * 8), "group_sum_i64 sums differ (n=%zu)", n);
    CHECK(!memcmp(gc1, gc2, ng * 8), "group_sum_i64 counts differ");
    if (n) {
      gid[rnd_below(n)] = (uint32_t)ng;
      memset(gs2, 0, ng * 8);
      int e1 = r->group_sum_i64(gid, data, NULL, n, gs1, NULL, ng);
      int e2 = v->group_sum_i64(gid, data, NULL, n, gs2, NULL, ng);
      CHECK(e1 == PQK_EINVAL && e2 == PQK_EINVAL, "group_sum_i64 out-of-range id: %d %d", e1, e2);
    }
    /* gather */
    size_t mm = n ? rnd_below(2 * n) : 0;
    uint32_t *idx = malloc(mm * 4 + 4);
    for (size_t j = 0; j < mm; j++) idx[j] = (uint32_t)rnd_below(n);
    int64_t *g1 = malloc(mm * 8 + 8), *g2 = malloc(mm * 8 + 8);
    r->gather_i64(data, idx, mm, g1); v->gather_i64(data, idx, mm, g2);
    CHECK(!memcmp(g1, g2, mm * 8), "gather_i64 m=%zu", mm);

    /* 128-bit kernels (CR-4) */
    int m128 = (int)rnd_below(5);
    ubuf w = ualloc(n * 16 + 16, rnd_below(16)), cab = ualloc(2 * sizeof(pqk_i128), rnd_below(16));
    pqk_i128 *wd = w.p, *ca = cab.p, *cb = ca + 1;
    for (size_t i = 0; i < n; i++) {
      __int128 x = (rnd() & 3) || i == 0 ? rand_i128(m128) : load_u(wd + rnd_below(i));
      pqk_i128 v = to_s(x);
      memcpy(wd + i, &v, sizeof v);
    }
    {
      __int128 av = (rnd() & 1) && n ? load_u(wd + rnd_below(n)) : rand_i128(m128), bv = rand_i128(m128);
      if (op == PQK_BETWEEN && av > bv) { __int128 t = av; av = bv; bv = t; }
      pqk_i128 as = to_s(av), bs = to_s(bv);
      memcpy(ca, &as, sizeof as);
      memcpy(cb, &bs, sizeof bs);
      const pqk_i128 *bp = op == PQK_BETWEEN ? cb : NULL;   /* b must not be read unless BETWEEN */
      c1 = r->filter_i128(wd, validity, n, op, ca, bp, i1);
      c2 = v->filter_i128(wd, validity, n, op, ca, bp, i2);
      CHECK(c1 == c2 && !memcmp(i1, i2, c1 * 4), "filter_i128 n=%zu op=%d mode=%d: %zu vs %zu", n, op, m128, c1, c2);
      CHECK(r->count_i128(wd, validity, n, op, ca, bp) == v->count_i128(wd, validity, n, op, ca, bp),
            "count_i128 n=%zu op=%d mode=%d", n, op, m128);
      CHECK(v->filter_i128(wd, validity, n, 7, NULL, NULL, i2) == (size_t)-1, "filter_i128 invalid op");
      CHECK(v->count_i128(wd, validity, n, -1, NULL, NULL) == (size_t)-1, "count_i128 invalid op");
      pqk_i128 q1 = {7, 7}, q2 = {7, 7}, x1 = {9, 9}, x2 = {9, 9};
      r1 = r->sum_i128(wd, validity, n, &q1);
      r2 = v->sum_i128(wd, validity, n, &q2);
      CHECK(r1 == r2 && (r1 != PQK_OK || !memcmp(&q1, &q2, sizeof q1)), "sum_i128 n=%zu mode=%d: %d vs %d", n, m128, r1, r2);
      c1 = r->minmax_i128(wd, validity, n, &q1, &x1);
      c2 = v->minmax_i128(wd, validity, n, &q2, &x2);
      CHECK(c1 == c2 && (!c1 || (!memcmp(&q1, &q2, sizeof q1) && !memcmp(&x1, &x2, sizeof x1))), "minmax_i128 n=%zu mode=%d", n, m128);
    }
    free(w.base); free(cab.base);

    free(d.base); free(d2.base); free(vb.base); free(i1); free(i2); free(b1); free(b2); free(fb.base);
    free(ba.base); free(bb.base); free(o1); free(o2); free(h1); free(h2); free(fa); free(fbx); free(co1); free(co2);
    free(gid); free(gs1); free(gs2); free(gc1); free(gc2); free(idx); free(g1); free(g2);
  }
}

static void known_answers(const char *vname, const pqk_table *v) {
  /* empty inputs with NULL pointers */
  int64_t s = 42;
  CHECK(v->sum_i64(NULL, NULL, 0, &s) == PQK_OK && s == 0, "sum of empty");
  int64_t lo = 1, hi = 2;
  CHECK(v->minmax_i64(NULL, NULL, 0, &lo, &hi) == 0 && lo == 1 && hi == 2, "minmax of empty");
  CHECK(v->filter_i64(NULL, NULL, 0, PQK_EQ, 0, 0, NULL) == 0, "filter of empty");
  CHECK(v->count_i64(NULL, NULL, 0, PQK_EQ, 0, 0) == 0, "count of empty");
  CHECK(v->bitmap_popcount(NULL, 0) == 0, "popcount of empty");
  CHECK(v->sum_f64(NULL, NULL, 0) == 0.0, "sum_f64 of empty");
  /* overflow: exact final sum semantics */
  int64_t ov[] = {INT64_MAX, 1, -1};
  CHECK(v->sum_i64(ov, NULL, 3, &s) == PQK_OK && s == INT64_MAX, "intermediate overflow that cancels out");
  int64_t ov2[] = {INT64_MAX, 1};
  CHECK(v->sum_i64(ov2, NULL, 2, &s) == PQK_OVERFLOW, "final overflow");
  int64_t ov3[] = {INT64_MIN, -1};
  CHECK(v->sum_i64(ov3, NULL, 2, &s) == PQK_OVERFLOW, "negative overflow");
  uint8_t only_first = 1;
  CHECK(v->sum_i64(ov2, &only_first, 2, &s) == PQK_OK && s == INT64_MAX, "validity respected in sum");
  /* large n crossing every SIMD block size, overflow far into the array */
  size_t n = 100003;
  int64_t *big = malloc(n * 8);
  for (size_t i = 0; i < n; i++) big[i] = INT64_MAX / 50000;
  CHECK(v->sum_i64(big, NULL, n, &s) == PQK_OVERFLOW, "accumulated overflow over large n");
  free(big);
  /* hash known answer: fmix64(0 ^ 0) == 0, fmix64(1) */
  int64_t hk[] = {0, 1, -1};
  uint64_t ho[3];
  v->hash_i64(hk, 3, 0, ho);
  CHECK(ho[0] == 0 && ho[1] == 0xb456bcfc34c2cb2cULL && ho[2] == 0x64b5720b4b825f21ULL,
        "hash known answers: %016llx %016llx %016llx", (unsigned long long)ho[0], (unsigned long long)ho[1], (unsigned long long)ho[2]);
  /* 128-bit kernels: empty inputs, exact-sum overflow semantics, limb boundaries */
  {
    const __int128 MAX = (__int128)(((unsigned __int128)1 << 127) - 1), MIN = -MAX - 1;
    pqk_i128 zero = {0, 0}, q = {5, 5}, x = {6, 6};
    CHECK(v->filter_i128(NULL, NULL, 0, PQK_EQ, &zero, NULL, NULL) == 0, "filter_i128 of empty");
    CHECK(v->count_i128(NULL, NULL, 0, PQK_BETWEEN, &zero, &zero) == 0, "count_i128 of empty");
    CHECK(v->sum_i128(NULL, NULL, 0, &q) == PQK_OK && q.lo == 0 && q.hi == 0, "sum_i128 of empty");
    CHECK(v->minmax_i128(NULL, NULL, 0, &q, &x) == 0 && q.lo == 0 && x.lo == 6, "minmax_i128 of empty");
    pqk_i128 c1[] = {to_s(MAX), to_s(1), to_s(-1)};
    CHECK(v->sum_i128(c1, NULL, 3, &q) == PQK_OK && from_s(q) == MAX, "sum_i128 intermediate overflow that cancels out");
    pqk_i128 c2[] = {to_s(MAX), to_s(1)};
    CHECK(v->sum_i128(c2, NULL, 2, &q) == PQK_OVERFLOW, "sum_i128 final overflow");
    pqk_i128 c3[] = {to_s(MIN), to_s(-1)};
    CHECK(v->sum_i128(c3, NULL, 2, &q) == PQK_OVERFLOW, "sum_i128 negative overflow");
    CHECK(v->sum_i128(c2, &only_first, 2, &q) == PQK_OK && from_s(q) == MAX, "sum_i128 validity respected");
    /* lane-wise accumulators must carry beyond 128 bits: 4*MAX + 4*MIN = -4 */
    pqk_i128 c4[16];
    for (int i = 0; i < 16; i++) c4[i] = to_s(i < 8 ? (i & 1 ? MAX : 0) : (i & 1 ? MIN : 0));
    CHECK(v->sum_i128(c4, NULL, 16, &q) == PQK_OK && from_s(q) == -4, "sum_i128 multi-wrap cancels: got hi=%lld", (long long)q.hi);
    size_t nb2 = 100003;
    pqk_i128 *bw = malloc(nb2 * sizeof *bw);
    for (size_t i = 0; i < nb2; i++) bw[i] = to_s(MAX / 50000);
    CHECK(v->sum_i128(bw, NULL, nb2, &q) == PQK_OVERFLOW, "sum_i128 accumulated overflow over large n");
    for (size_t i = 0; i < nb2; i++) bw[i] = to_s(i & 1 ? -(MAX / 3) : MAX / 3);
    CHECK(v->sum_i128(bw, NULL, nb2, &q) == PQK_OK && from_s(q) == MAX / 3, "sum_i128 alternating large n");
    free(bw);
    /* signed-high / unsigned-low ordering: -1 < 0 < 2^63 < 2^64, MIN < everything */
    pqk_i128 ord[] = {to_s((__int128)1 << 64), to_s(-1), to_s((__int128)INT64_MAX + 1), to_s(0), to_s(MIN), to_s(MAX)};
    CHECK(v->minmax_i128(ord, NULL, 6, &q, &x) == 6 && from_s(q) == MIN && from_s(x) == MAX, "minmax_i128 extremes");
    CHECK(v->minmax_i128(ord, NULL, 4, &q, &x) == 4 && from_s(q) == -1 && from_s(x) == (__int128)1 << 64, "minmax_i128 limb order");
    pqk_i128 t63 = to_s((__int128)INT64_MAX + 1);
    CHECK(v->count_i128(ord, NULL, 6, PQK_LT, &t63, NULL) == 3, "count_i128 LT 2^63 (signed-high/unsigned-low)");
    CHECK(v->count_i128(ord, NULL, 6, PQK_GE, &t63, NULL) == 3, "count_i128 GE 2^63");
  }
  /* popcount tail */
  uint8_t pb[] = {0xFF, 0xFF, 0x0F};
  CHECK(v->bitmap_popcount(pb, 19) == 19 && v->bitmap_popcount(pb, 16) == 16 && v->bitmap_popcount(pb, 20) == 20, "popcount tails");
}

int main(int argc, char **argv) {
  int iters = argc > 1 ? atoi(argv[1]) : 2000;
  if (argc > 2) rs = strtoull(argv[2], NULL, 10);
  pqk_init();
  pqk_table ref;
  pqk_variant_table("reference", &ref);
  const char *vname = "reference";
  known_answers(vname, &ref);
  const char *variants[] = {"x86_scalar", "x86_avx2", "x86_avx512", "a64_scalar", "a64_neon", "a64_sve"};
  int tested = 0;
  printf("available variants: %s (default: %s)\n", pqk_available_variants(), pqk_variant());
  for (size_t k = 0; k < sizeof variants / sizeof variants[0]; k++) {
    pqk_table t;
    vname = variants[k];
    int provided = pqk_variant_table(vname, &t);
    if (provided == 0) continue;
    if (!pqk_cpu_supports(vname)) {
      printf("  %-11s built (%d/%d kernels) but SKIPPED: CPU lacks required features\n", vname, provided, PQK_NKERNELS);
      continue;
    }
    int before = failures;
    known_answers(vname, &t);
    test_variant(vname, &t, &ref, iters);
    printf("  %-11s %2d/%d kernels  %s\n", vname, provided, PQK_NKERNELS, failures == before ? "PASS" : "FAIL");
    tested++;
  }
  printf("kernel tests: %d variant(s) tested, %d failure(s)\n", tested, failures);
  return failures ? 1 : 0;
}
