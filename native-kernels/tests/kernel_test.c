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
    int64_t a = rnd() & 1 ? rand_i64(mode) : (n ? data[rnd_below(n)] : 0), b = rand_i64(mode);
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
      printf("  %-11s built (%d/16 kernels) but SKIPPED: CPU lacks required features\n", vname, provided);
      continue;
    }
    int before = failures;
    known_answers(vname, &t);
    test_variant(vname, &t, &ref, iters);
    printf("  %-11s %2d/16 kernels  %s\n", vname, provided, failures == before ? "PASS" : "FAIL");
    tested++;
  }
  printf("kernel tests: %d variant(s) tested, %d failure(s)\n", tested, failures);
  return failures ? 1 : 0;
}
