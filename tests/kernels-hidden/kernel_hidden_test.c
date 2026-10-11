/*
 * Hidden kernel acceptance tests (never copied into an agent workspace).
 * Large inputs that cross 2^16 / 2^17 / 2^20 element boundaries, extra seeds and
 * every operator, each variant vs. the C reference. Reuses the public test's
 * helpers and also runs the public suite with a different seed.
 *
 * Built by `make -C native-kernels test-hidden HIDDEN_SRC=<this file>`.
 */
#define main public_main
#include "kernel_test.c"  /* via -Itests */
#undef main

static void large(const char *vname, const pqk_table *v, const pqk_table *r, size_t n, size_t off) {
  ubuf d = ualloc(n * 8 + 8, off), d2 = ualloc(n * 8 + 8, (off + 3) & 7), vb = ualloc(n / 8 + 2, off & 3);
  ubuf w = ualloc(n * 16 + 16, (off * 5) & 15);
  int64_t *data = d.p, *data2 = d2.p;
  pqk_i128 *wd = w.p;
  uint8_t *validity = vb.p;
  size_t nb = (n + 7) / 8;
  for (size_t i = 0; i < n; i++) {
    int64_t x = (int64_t)rnd_below(1000) - 500, y = (rnd() & 1) ? x : (int64_t)rnd_below(1000) - 500;
    memcpy(data + i, &x, 8);
    memcpy(data2 + i, &y, 8);
    pqk_i128 q = to_s((__int128)x * (__int128)UINT64_MAX + (__int128)(rnd() & 7));
    memcpy(wd + i, &q, sizeof q);
  }
  for (size_t i = 0; i < nb; i++) validity[i] = (uint8_t)(rnd() | 0x81);
  uint32_t *i1 = malloc(n * 4 + 4), *i2 = malloc(n * 4 + 4);
  uint8_t *b1 = malloc(nb + 1), *b2 = malloc(nb + 1);
  for (int op = PQK_EQ; op <= PQK_BETWEEN; op++) {
    for (int useval = 0; useval < 2; useval++) {
      const uint8_t *val = useval ? validity : NULL;
      int64_t a = -100, b = 250;
      size_t c1 = r->filter_i64(data, val, n, op, a, b, i1), c2 = v->filter_i64(data, val, n, op, a, b, i2);
      CHECK(c1 == c2 && !memcmp(i1, i2, c1 * 4), "large filter_i64 n=%zu op=%d val=%d: %zu vs %zu", n, op, useval, c1, c2);
      c1 = r->filter_i64_bitmap(data, val, n, op, a, b, b1);
      c2 = v->filter_i64_bitmap(data, val, n, op, a, b, b2);
      CHECK(c1 == c2 && !memcmp(b1, b2, nb), "large filter_i64_bitmap n=%zu op=%d", n, op);
      CHECK(r->count_i64(data, val, n, op, a, b) == v->count_i64(data, val, n, op, a, b), "large count_i64 n=%zu op=%d", n, op);
      pqk_i128 qa = to_s((__int128)-100 * (__int128)UINT64_MAX), qb = to_s((__int128)250 * (__int128)UINT64_MAX);
      c1 = r->filter_i128(wd, val, n, op, &qa, &qb, i1);
      c2 = v->filter_i128(wd, val, n, op, &qa, &qb, i2);
      CHECK(c1 == c2 && !memcmp(i1, i2, c1 * 4), "large filter_i128 n=%zu op=%d val=%d: %zu vs %zu", n, op, useval, c1, c2);
      CHECK(r->count_i128(wd, val, n, op, &qa, &qb) == v->count_i128(wd, val, n, op, &qa, &qb), "large count_i128 n=%zu op=%d", n, op);
      if (op < PQK_BETWEEN) {
        c1 = r->compare_i64(data, data2, n, op, b1);
        c2 = v->compare_i64(data, data2, n, op, b2);
        CHECK(c1 == c2 && !memcmp(b1, b2, nb), "large compare_i64 n=%zu op=%d", n, op);
      }
    }
  }
  int64_t s1 = 0, s2 = 0, lo1 = 0, hi1 = 0, lo2 = 0, hi2 = 0;
  int r1 = r->sum_i64(data, validity, n, &s1), r2 = v->sum_i64(data, validity, n, &s2);
  CHECK(r1 == r2 && s1 == s2, "large sum_i64 n=%zu", n);
  size_t k1 = r->minmax_i64(data, validity, n, &lo1, &hi1), k2 = v->minmax_i64(data, validity, n, &lo2, &hi2);
  CHECK(k1 == k2 && lo1 == lo2 && hi1 == hi2, "large minmax_i64 n=%zu", n);
  pqk_i128 q1 = {0, 0}, q2 = {0, 0}, x1 = {0, 0}, x2 = {0, 0};
  r1 = r->sum_i128(wd, validity, n, &q1);
  r2 = v->sum_i128(wd, validity, n, &q2);
  CHECK(r1 == r2 && !memcmp(&q1, &q2, sizeof q1), "large sum_i128 n=%zu", n);
  k1 = r->minmax_i128(wd, validity, n, &q1, &x1);
  k2 = v->minmax_i128(wd, validity, n, &q2, &x2);
  CHECK(k1 == k2 && !memcmp(&q1, &q2, sizeof q1) && !memcmp(&x1, &x2, sizeof x1), "large minmax_i128 n=%zu", n);
  CHECK(r->bitmap_popcount(validity, n) == v->bitmap_popcount(validity, n), "large bitmap_popcount n=%zu", n);
  uint64_t *h1 = malloc(n * 8 + 8), *h2 = malloc(n * 8 + 8);
  r->hash_i64(data, n, 0x5eed, h1);
  v->hash_i64(data, n, 0x5eed, h2);
  CHECK(!memcmp(h1, h2, n * 8), "large hash_i64 n=%zu", n);
  size_t ng = 70001;
  uint32_t *gid = malloc(n * 4 + 4);
  for (size_t i = 0; i < n; i++) gid[i] = (uint32_t)rnd_below(ng);
  int64_t *gs1 = calloc(ng, 8), *gs2 = calloc(ng, 8), *gc1 = calloc(ng, 8), *gc2 = calloc(ng, 8);
  r1 = r->group_sum_i64(gid, data, validity, n, gs1, gc1, ng);
  r2 = v->group_sum_i64(gid, data, validity, n, gs2, gc2, ng);
  CHECK(r1 == r2 && !memcmp(gs1, gs2, ng * 8) && !memcmp(gc1, gc2, ng * 8), "large group_sum_i64 n=%zu", n);
  for (size_t j = 0; j < n; j++) i1[j] = (uint32_t)(n - 1 - j);
  int64_t *g1 = malloc(n * 8 + 8), *g2 = malloc(n * 8 + 8);
  r->gather_i64(data, i1, n, g1);
  v->gather_i64(data, i1, n, g2);
  CHECK(!memcmp(g1, g2, n * 8), "large gather_i64 n=%zu", n);
  free(d.base); free(d2.base); free(vb.base); free(w.base); free(i1); free(i2); free(b1); free(b2);
  free(h1); free(h2); free(gid); free(gs1); free(gs2); free(gc1); free(gc2); free(g1); free(g2);
}

int main(int argc, char **argv) {
  int iters = argc > 1 ? atoi(argv[1]) : 600;
  pqk_init();
  pqk_table ref;
  pqk_variant_table("reference", &ref);
  const char *variants[] = {"x86_scalar", "x86_avx2", "x86_avx512", "a64_scalar", "a64_neon", "a64_sve"};
  const size_t sizes[] = {65535, 65536, 65537, 131073, (1u << 20) + 5};
  int tested = 0;
  for (size_t k = 0; k < sizeof variants / sizeof variants[0]; k++) {
    pqk_table t;
    const char *vname = variants[k];
    int provided = pqk_variant_table(vname, &t);
    if (provided == 0 || !pqk_cpu_supports(vname)) continue;
    int before = failures;
    for (uint64_t seed = 1; seed <= 3; seed++) {
      rs = 0xC0FFEE00ULL + seed * 7919;
      test_variant(vname, &t, &ref, iters);
    }
    for (size_t s = 0; s < sizeof sizes / sizeof sizes[0]; s++) large(vname, &t, &ref, sizes[s], s & 7);
    printf("  %-11s %2d/%d kernels  hidden %s\n", vname, provided, PQK_NKERNELS, failures == before ? "PASS" : "FAIL");
    tested++;
  }
  printf("hidden kernel tests: %d variant(s) tested, %d failure(s)\n", tested, failures);
  return failures ? 1 : 0;
}
