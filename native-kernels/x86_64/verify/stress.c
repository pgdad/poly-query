/* TEST TOOL (not part of libpqkernels): randomized differential stress test
 * for the throughput rewrites. Unlike tests/kernel_test.c (n < 5000, bitmaps
 * < 200 bytes) it uses sizes up to ~70000 rows / 20000 bitmap bytes, so the
 * large-block paths (e.g. the 640-byte popcount loop, 16-row-unrolled loops,
 * sum chunk folds with -DSUM_CHUNK_ROWS) run, plus adversarial columns
 * (ascending, descending, constant, extremes, alternating signs, near-bound
 * values) and edge constants (INT64_MIN/MAX bounds, a > b, BETWEEN with
 * a == b). Every buffer is placed against a PROT_NONE guard page (end or
 * start, alternating), so out-of-bounds reads/writes by the assembly fault.
 * Usage: stress [iterations] [seed] [variant]. Build: see run.sh. */
#define _GNU_SOURCE
#include "pq_kernels_internal.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static size_t PG;
static uint64_t rs = 99;
static uint64_t rnd(void){uint64_t z=(rs+=0x9E3779B97F4A7C15ULL);z=(z^(z>>30))*0xBF58476D1CE4E5B9ULL;z=(z^(z>>27))*0x94D049BB133111EBULL;return z^(z>>31);}
static size_t below(size_t n){ return n ? rnd() % n : 0; }
typedef struct { void *map; size_t len; } gb;
static gb pool[256]; static int npool;
static void *gal(size_t bytes, int mode) {
  size_t body = (bytes + PG - 1) / PG * PG + PG;
  size_t len = body + 2 * PG;
  unsigned char *m = mmap(NULL, len, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
  if (m == MAP_FAILED) { perror("mmap"); exit(2); }
  mprotect(m, PG, PROT_NONE);
  mprotect(m + PG + body, PG, PROT_NONE);
  pool[npool].map = m; pool[npool++].len = len;
  if (bytes == 0) return mode ? m + PG : m + PG + body;
  return mode ? m + PG : m + PG + body - bytes;
}
static void gfree(void){ for(int i=0;i<npool;i++) munmap(pool[i].map,pool[i].len); npool=0; }
static int fails; static const char *vn;
#define CK(c, ...) do{ if(!(c)){ fails++; if(fails<40){fprintf(stderr,"FAIL %s: ",vn);fprintf(stderr,__VA_ARGS__);fputc('\n',stderr);} } }while(0)

static size_t pick_n(void) {
  switch (below(8)) {
  case 0: return below(70);
  case 1: { size_t k = 64 * below(40) + below(3); return k ? k - below(2) : 0; }   /* near block multiples */
  case 2: return below(1200);
  case 3: return 640 + below(4000);
  case 4: return below(70000);
  case 5: return 16 * below(300) + below(16);
  default: return below(9000);
  }
}
static int64_t gen64(int mode, size_t i, size_t n) {
  switch (mode) {
  case 0: return (int64_t)below(1000000);
  case 1: return (int64_t)rnd();
  case 2: return (int64_t)i - (int64_t)(n / 2);                  /* ascending */
  case 3: return (int64_t)(n - i) * 1000003;                     /* descending */
  case 4: return 42;
  case 5: { static const int64_t ex[] = {INT64_MIN, INT64_MAX, INT64_MIN + 1, INT64_MAX - 1, -1, 0, 1};
            return ex[below(7)]; }
  case 6: return (i & 1) ? INT64_MAX : INT64_MIN + 1;
  case 7: return (int64_t)(rnd() >> below(64)) * ((rnd() & 1) ? 1 : -1);
  default: return (int64_t)below(7) - 3;
  }
}
static __int128 gen128(int mode, size_t i, size_t n) {
  const __int128 MAX = (__int128)(((unsigned __int128)1 << 127) - 1), MIN = -MAX - 1;
  switch (mode) {
  case 0: return (__int128)(int64_t)below(1000000) * ((__int128)10000000000LL * 10000000000LL) * ((i & 3) ? 1 : -1);
  case 1: return (__int128)(((unsigned __int128)rnd() << 64) | rnd());
  case 2: return (__int128)i - (__int128)(n / 2);
  case 3: return ((__int128)n - (__int128)i) << 64;
  case 4: return (i & 1) ? MAX : MIN + 1;
  case 5: { __int128 ex[] = {MAX, MIN, MAX - 1, MIN + 1, -1, 0, 1, (__int128)INT64_MIN, (__int128)UINT64_MAX, -(__int128)UINT64_MAX};
            return ex[below(10)]; }
  case 6: return (__int128)(int64_t)below(7) - 3;
  case 7: { int64_t hi = (int64_t)below(3) - 1; uint64_t lo = (rnd() & 1) ? rnd() : (rnd() & 1) ? UINT64_MAX - below(3) : below(3);
            return (__int128)(((unsigned __int128)(uint64_t)hi << 64) | lo); }
  case 8: { /* quick-reject edge: hi in [-1000, 1000]; late rows tie the extreme high words with smaller / larger low words */
            int64_t hi = (int64_t)below(2001) - 1000; uint64_t lo = rnd();
            if (i > n / 2 && below(500) == 0) { hi = (rnd() & 1) ? -1000 : 1000; lo = (rnd() & 1) ? below(3) : UINT64_MAX - below(3); }
            return (__int128)(((unsigned __int128)(uint64_t)hi << 64) | lo); }
  default: return (__int128)(((unsigned __int128)rnd() << 64) | rnd()) >> below(127);
  }
}
static int64_t pick_const(const int64_t *d, size_t n, int mode) {
  switch (below(6)) {
  case 0: return n ? d[below(n)] : 0;
  case 1: return INT64_MIN;
  case 2: return INT64_MAX;
  case 3: return gen64(mode, below(n + 1), n);
  default: return n ? (int64_t)((uint64_t)d[below(n)] + below(3) - 1) : 0;
  }
}
static int bitv(const uint8_t *v, size_t i) { return !v || (v[i >> 3] >> (i & 7) & 1); }

int main(int argc, char **argv) {
  PG = (size_t)sysconf(_SC_PAGESIZE);
  int iters = argc > 1 ? atoi(argv[1]) : 300;
  if (argc > 2) rs = strtoull(argv[2], NULL, 10);
  const char *only = argc > 3 ? argv[3] : NULL;
  pqk_table ref, v; pqk_variant_table("reference", &ref);
  const char *vars[] = {"x86_scalar", "x86_avx2", "x86_avx512"};
  for (int vi = 0; vi < 3; vi++) {
    vn = vars[vi];
    if (only && strcmp(only, vn)) continue;
    if (!pqk_variant_table(vn, &v) || !pqk_cpu_supports(vn)) continue;
    int f0 = fails;
    for (int it = 0; it < iters; it++) {
      int gm = (int)(it & 1);
      size_t n = pick_n(), nb = (n + 7) / 8;
      int mode = (int)below(9);
      int64_t *d = gal(n * 8, gm), *d2 = gal(n * 8, gm);
      for (size_t i = 0; i < n; i++) { d[i] = gen64(mode, i, n); d2[i] = (rnd() & 3) ? (int64_t)((uint64_t)d[i] + below(3) - 1) : gen64(mode, i, n); }
      uint8_t *val = NULL;
      int vmode = (int)below(5);
      if (vmode) {
        val = gal(nb, gm);
        for (size_t i = 0; i < nb; i++) val[i] = vmode == 1 ? 0xff : vmode == 2 ? 0 : vmode == 3 ? (uint8_t)(rnd() & rnd() & rnd()) : (uint8_t)rnd();
      }
      uint32_t *o1 = calloc(n + 1, 4), *o2 = gal(n * 4, gm);
      uint8_t *b1 = calloc(nb + 1, 1), *b2 = gal(nb, gm);
      for (int op = 0; op < 7; op++) {
        int64_t a = pick_const(d, n, mode), b = pick_const(d, n, mode);
        if (op == PQK_BETWEEN && (rnd() & 3) && a > b) { int64_t t = a; a = b; b = t; }
        if (op == PQK_BETWEEN && below(8) == 0) b = a;
        size_t c1 = ref.filter_i64(d, val, n, op, a, b, o1), c2 = v.filter_i64(d, val, n, op, a, b, o2);
        CK(c1 == c2 && !memcmp(o1, o2, c1 * 4), "filter_i64 n=%zu op=%d mode=%d a=%lld b=%lld: %zu vs %zu", n, op, mode, (long long)a, (long long)b, c1, c2);
        c1 = ref.filter_i64_bitmap(d, val, n, op, a, b, b1); c2 = v.filter_i64_bitmap(d, val, n, op, a, b, b2);
        CK(c1 == c2 && !memcmp(b1, b2, nb), "filter_i64_bitmap n=%zu op=%d mode=%d", n, op, mode);
        c1 = ref.count_i64(d, val, n, op, a, b); c2 = v.count_i64(d, val, n, op, a, b);
        CK(c1 == c2, "count_i64 n=%zu op=%d mode=%d a=%lld b=%lld: %zu vs %zu", n, op, mode, (long long)a, (long long)b, c1, c2);
        if (op < 6) { c1 = ref.compare_i64(d, d2, n, op, b1); c2 = v.compare_i64(d, d2, n, op, b2); CK(c1 == c2 && !memcmp(b1, b2, nb), "compare_i64 n=%zu op=%d", n, op); }
      }
      CK(v.filter_i64(d, val, n, 7, 0, 0, o2) == (size_t)-1 && v.count_i64(d, val, n, -1, 0, 0) == (size_t)-1, "invalid op");
      int64_t s1 = 0, s2 = 0; int r1 = ref.sum_i64(d, val, n, &s1), r2 = v.sum_i64(d, val, n, &s2);
      CK(r1 == r2 && (r1 || s1 == s2), "sum_i64 n=%zu mode=%d vmode=%d: %d/%lld vs %d/%lld", n, mode, vmode, r1, (long long)s1, r2, (long long)s2);
      int64_t l1 = 0, h1 = 0, l2 = 0, h2 = 0; size_t k1 = ref.minmax_i64(d, val, n, &l1, &h1), k2 = v.minmax_i64(d, val, n, &l2, &h2);
      CK(k1 == k2 && (!k1 || (l1 == l2 && h1 == h2)), "minmax_i64 n=%zu mode=%d", n, mode);
      /* doubles */
      double *f = gal(n * 8, gm), sabs = 0;
      for (size_t i = 0; i < n; i++) {
        double x = mode == 2 ? (double)i : mode == 3 ? -(double)i : ((double)(int64_t)(rnd() >> 11) / 9007199254740992.0) * (double)(1 << below(30)) * ((rnd() & 1) ? 1 : -1);
        if (below(50) == 0) x = (rnd() & 1) ? 0.0 : -0.0;
        f[i] = x; if (bitv(val, i)) sabs += fabs(x);
      }
      double fs1 = ref.sum_f64(f, val, n), fs2 = v.sum_f64(f, val, n);
      CK(fabs(fs1 - fs2) <= (double)(n + 1) * 2.3e-16 * sabs + 1e-300, "sum_f64 n=%zu", n);
      double fl1 = 0, fh1 = 0, fl2 = 0, fh2 = 0; k1 = ref.minmax_f64(f, val, n, &fl1, &fh1); k2 = v.minmax_f64(f, val, n, &fl2, &fh2);
      CK(k1 == k2 && (!k1 || (!memcmp(&fl1, &fl2, 8) && !memcmp(&fh1, &fh2, 8))), "minmax_f64 n=%zu", n);
      uint64_t seed = rnd(), *hh1 = calloc(n + 1, 8), *hh2 = gal(n * 8, gm);
      ref.hash_i64(d, n, seed, hh1); v.hash_i64(d, n, seed, hh2); CK(!memcmp(hh1, hh2, n * 8), "hash_i64 n=%zu", n);
      /* bitmaps */
      size_t nbytes = below(4) ? below(3000) : below(20000);
      uint8_t *x = gal(nbytes, gm), *y = gal(nbytes, gm), *z1 = calloc(nbytes + 1, 1), *z2 = gal(nbytes, gm);
      int bm = (int)below(4);
      for (size_t i = 0; i < nbytes; i++) { x[i] = bm == 0 ? 0xff : bm == 1 ? 0 : (uint8_t)rnd(); y[i] = (uint8_t)rnd(); }
      ref.bitmap_and(x, y, z1, nbytes); v.bitmap_and(x, y, z2, nbytes); CK(!memcmp(z1, z2, nbytes), "bitmap_and %zu", nbytes);
      ref.bitmap_or(x, y, z1, nbytes); v.bitmap_or(x, y, z2, nbytes); CK(!memcmp(z1, z2, nbytes), "bitmap_or %zu", nbytes);
      ref.bitmap_andnot(x, y, z1, nbytes); v.bitmap_andnot(x, y, z2, nbytes); CK(!memcmp(z1, z2, nbytes), "bitmap_andnot %zu", nbytes);
      memcpy(z2, x, nbytes); v.bitmap_or(z2, y, z2, nbytes); ref.bitmap_or(x, y, z1, nbytes); CK(!memcmp(z1, z2, nbytes), "bitmap_or alias %zu", nbytes);
      for (int t = 0; t < 4 && nbytes; t++) { size_t nbits = nbytes * 8 - below(8); if (t) nbits -= below(nbits + 1);
        CK(ref.bitmap_popcount(x, nbits) == v.bitmap_popcount(x, nbits), "bitmap_popcount nbits=%zu", nbits); }
      /* compare_fixed */
      { size_t w = below(4) ? below(40) : below(200), m = below(4) ? below(300) : below(3000);
        uint8_t *fa = gal(w * m, gm), *fb = gal(w * m, gm); int8_t *q1 = calloc(m + 1, 1), *q2 = gal(m, gm);
        for (size_t i = 0; i < w * m; i++) { fa[i] = (uint8_t)below(3); fb[i] = below(w + 1) == 0 ? (uint8_t)rnd() : fa[i]; }
        ref.compare_fixed(fa, fb, w, m, q1); v.compare_fixed(fa, fb, w, m, q2); CK(!memcmp(q1, q2, m), "compare_fixed w=%zu m=%zu", w, m); free(q1); }
      /* group_sum: values from d (extremes possible -> overflow flag) */
      { size_t ng = below(3) ? 1 + below(2000) : 1 + below(8); uint32_t *g = gal(n * 4, gm);
        for (size_t i = 0; i < n; i++) g[i] = (uint32_t)(below(4) ? below(ng) : (i * 7) % ng);
        int64_t *gs1 = calloc(ng, 8), *gs2 = gal(ng * 8, gm), *gc1 = calloc(ng, 8), *gc2 = gal(ng * 8, gm);
        int initm = (int)below(4);   /* 3: some initial sums near the int64 limits / +-2^62 */
        for (size_t i = 0; i < ng; i++) { gs1[i] = gs2[i] = (int64_t)below(5); gc1[i] = gc2[i] = (int64_t)below(5);
          if (initm == 3 && below(50) == 0) { static const int64_t ex[] = {INT64_MAX, INT64_MIN, (int64_t)1 << 62, -((int64_t)1 << 62), ((int64_t)1 << 62) - 1, -((int64_t)1 << 62) - 1};
            gs1[i] = gs2[i] = ex[below(6)]; } }
        int nocnt = below(4) == 0;
        r1 = ref.group_sum_i64(g, d, val, n, gs1, nocnt ? NULL : gc1, ng); r2 = v.group_sum_i64(g, d, val, n, gs2, nocnt ? NULL : gc2, ng);
        CK(r1 == r2 && !memcmp(gs1, gs2, ng * 8) && (nocnt || !memcmp(gc1, gc2, ng * 8)), "group_sum n=%zu ng=%zu mode=%d %d %d", n, ng, mode, r1, r2);
        if (n) { size_t bad = below(n); g[bad] = (uint32_t)(ng + below(3));
          r1 = ref.group_sum_i64(g, d, val, n, gs1, gc1, ng); r2 = v.group_sum_i64(g, d, val, n, gs2, gc2, ng);
          CK(r1 == r2 && !memcmp(gs1, gs2, ng * 8) && !memcmp(gc1, gc2, ng * 8), "group_sum einval n=%zu %d %d", n, r1, r2); }
        free(gs1); free(gc1); }
      /* gather */
      { size_t m = n ? below(2 * n + 1) : 0; uint32_t *ix = gal(m * 4, gm); for (size_t i = 0; i < m; i++) ix[i] = (uint32_t)below(n);
        int64_t *g1 = calloc(m + 1, 8), *g2 = gal(m * 8, gm); ref.gather_i64(d, ix, m, g1); v.gather_i64(d, ix, m, g2);
        CK(!memcmp(g1, g2, m * 8), "gather m=%zu", m); free(g1); }
      if (below(8) == 0) {   /* large span: the AVX2 prefetching gather path (sampled index >= 2^19) */
        size_t nb2 = ((size_t)1 << 19) + below(1 << 18), m = below(6000); int64_t *bd = gal(nb2 * 8, gm); uint32_t *ix = gal(m * 4, gm);
        for (size_t i = 0; i < nb2; i += 1 + below(64)) bd[i] = (int64_t)rnd();
        for (size_t i = 0; i < m; i++) ix[i] = (uint32_t)(below(4) ? below(nb2) : nb2 - 1 - below(8));
        int64_t *g1 = calloc(m + 1, 8), *g2 = gal(m * 8, gm); ref.gather_i64(bd, ix, m, g1); v.gather_i64(bd, ix, m, g2);
        CK(!memcmp(g1, g2, m * 8), "gather (large span) m=%zu", m); free(g1); }
      /* 128-bit */
      { size_t m = n / (1 + below(3)); int m128 = (int)below(10);
        pqk_i128 *w = gal(m * 16, gm), *ca = gal(16, gm), *cb = gal(16, gm);
        for (size_t i = 0; i < m; i++) { __int128 q = gen128(m128, i, m); w[i].lo = (uint64_t)q; w[i].hi = (int64_t)(q >> 64); }
        for (int op = 0; op < 7; op++) {
          int c = (int)below(5);
          if (c == 0 && m) *ca = w[below(m)];
          else if (c == 1) { ca->lo = 0; ca->hi = INT64_MIN; }
          else if (c == 2) { ca->lo = UINT64_MAX; ca->hi = INT64_MAX; }
          else { __int128 q = gen128(m128, below(m + 1), m); ca->lo = (uint64_t)q; ca->hi = (int64_t)(q >> 64); }
          if (below(3) == 0 && m) *cb = w[below(m)];
          else { __int128 q = gen128(m128, below(m + 1), m); cb->lo = (uint64_t)q; cb->hi = (int64_t)(q >> 64); }
          if (below(5) == 0) *cb = *ca;
          __int128 qa = (__int128)(((unsigned __int128)(uint64_t)ca->hi << 64) | ca->lo), qb = (__int128)(((unsigned __int128)(uint64_t)cb->hi << 64) | cb->lo);
          if (op == PQK_BETWEEN && (rnd() & 3) && qa > qb) { pqk_i128 t = *ca; *ca = *cb; *cb = t; }
          const pqk_i128 *bp = op == PQK_BETWEEN ? cb : NULL;
          size_t c1 = ref.filter_i128(w, val, m, op, ca, bp, o1), c2 = v.filter_i128(w, val, m, op, ca, bp, o2);
          CK(c1 == c2 && !memcmp(o1, o2, c1 * 4), "filter_i128 m=%zu op=%d mode=%d", m, op, m128);
          c1 = ref.count_i128(w, val, m, op, ca, bp); c2 = v.count_i128(w, val, m, op, ca, bp);
          CK(c1 == c2, "count_i128 m=%zu op=%d mode=%d: %zu vs %zu", m, op, m128, c1, c2);
        }
        CK(v.count_i128(w, val, m, 9, NULL, NULL) == (size_t)-1, "count_i128 invalid op");
        pqk_i128 *q2 = gal(16, gm), *x2 = gal(16, gm), q1 = {0, 0}, x1 = {0, 0};
        r1 = ref.sum_i128(w, val, m, &q1); r2 = v.sum_i128(w, val, m, q2);
        CK(r1 == r2 && (r1 || !memcmp(&q1, q2, 16)), "sum_i128 m=%zu mode=%d", m, m128);
        k1 = ref.minmax_i128(w, val, m, &q1, &x1); k2 = v.minmax_i128(w, val, m, q2, x2);
        CK(k1 == k2 && (!k1 || (!memcmp(&q1, q2, 16) && !memcmp(&x1, x2, 16))), "minmax_i128 m=%zu mode=%d", m, m128); }
      free(o1); free(b1); free(hh1); free(z1);
      gfree();
    }
    printf("stress %s: %s (%d iterations)\n", vn, fails == f0 ? "ok" : "FAIL", iters);
  }
  return fails != 0;
}
