/* Kernel micro-benchmark: median ns/element per variant and kernel; JSON lines on stdout.
 * Usage: kernel_bench [n] [reps] */
#define _POSIX_C_SOURCE 199309L
#include "pq_kernels_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e9 + ts.tv_nsec;
}
static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }

static volatile uint64_t sink;

int main(int argc, char **argv) {
  size_t n = argc > 1 ? strtoull(argv[1], NULL, 10) : (1u << 22);
  int reps = argc > 2 ? atoi(argv[2]) : 15;
  pqk_init();
  int64_t *d = malloc(n * 8), *d2 = malloc(n * 8), *out64 = malloc(n * 8);
  double *f = malloc(n * 8);
  uint32_t *idx = malloc(n * 4), *gid = malloc(n * 4);
  uint8_t *bm = malloc(n / 8 + 1), *bm2 = malloc(n / 8 + 1), *bo = malloc(n / 8 + 1), *val = malloc(n / 8 + 1);
  uint64_t *h = malloc(n * 8);
  uint64_t s = 88172645463325252ULL;
  for (size_t i = 0; i < n; i++) {
    s ^= s << 13; s ^= s >> 7; s ^= s << 17;
    d[i] = (int64_t)(s % 1000000); d2[i] = (int64_t)((s >> 20) % 1000000); f[i] = (double)(s % 100000) / 7.0;
    idx[i] = (uint32_t)(s % n); gid[i] = (uint32_t)(s % 1024);
  }
  for (size_t i = 0; i < n / 8 + 1; i++) { bm[i] = (uint8_t)(i * 37); bm2[i] = (uint8_t)(i * 91); val[i] = 0xF7; }
  int64_t *gs = calloc(1024, 8), *gc = calloc(1024, 8);
  /* 128-bit decimals: unscaled = d * 10^20 (values need the high limb). */
  pqk_i128 *w = malloc(n * sizeof *w);
  const __int128 E20 = (__int128)10000000000ULL * 10000000000ULL;
  for (size_t i = 0; i < n; i++) {
    __int128 x = (__int128)d[i] * E20 * ((i & 3) ? 1 : -1);
    w[i].lo = (uint64_t)x; w[i].hi = (int64_t)(x >> 64);
  }
  __int128 wa = (__int128)-500000 * E20, wb = (__int128)100000 * E20;
  pqk_i128 ca = {(uint64_t)wa, (int64_t)(wa >> 64)}, cb = {(uint64_t)wb, (int64_t)(wb >> 64)};
  const char *variants[] = {"reference", "x86_scalar", "x86_avx2", "x86_avx512", "a64_scalar", "a64_neon", "a64_sve"};
  const char *kernels[] = {"filter_i64_sel10", "filter_i64_bitmap", "count_i64_between", "sum_i64", "sum_i64_validity",
                           "sum_f64", "minmax_i64", "bitmap_and", "bitmap_popcount", "hash_i64", "compare_i64",
                           "group_sum_i64_1024", "gather_i64",
                           "filter_i128_sel10", "count_i128_between", "sum_i128", "minmax_i128"};
  for (size_t vk = 0; vk < sizeof variants / sizeof *variants; vk++) {
    pqk_table t;
    if (!pqk_cpu_supports(variants[vk]) || pqk_variant_table(variants[vk], &t) == 0) continue;
    for (size_t kk = 0; kk < sizeof kernels / sizeof *kernels; kk++) {
      double *ts = malloc(sizeof(double) * reps);
      for (int r = -2; r < reps; r++) {
        int64_t a = 0, b = 0;
        double t0 = now_ns();
        switch (kk) {
        case 0: sink += t.filter_i64(d, NULL, n, PQK_LT, 100000, 0, idx); break;
        case 1: sink += t.filter_i64_bitmap(d, NULL, n, PQK_GE, 500000, 0, bo); break;
        case 2: sink += t.count_i64(d, NULL, n, PQK_BETWEEN, 1000, 600000); break;
        case 3: t.sum_i64(d, NULL, n, &a); sink += (uint64_t)a; break;
        case 4: t.sum_i64(d, val, n, &a); sink += (uint64_t)a; break;
        case 5: sink += (uint64_t)t.sum_f64(f, NULL, n); break;
        case 6: t.minmax_i64(d, NULL, n, &a, &b); sink += (uint64_t)(a + b); break;
        case 7: t.bitmap_and(bm, bm2, bo, n / 8); sink += bo[0]; break;
        case 8: sink += t.bitmap_popcount(bm, n); break;
        case 9: t.hash_i64(d, n, 42, h); sink += h[n - 1]; break;
        case 10: sink += t.compare_i64(d, d2, n, PQK_LT, bo); break;
        case 11: memset(gs, 0, 8192); t.group_sum_i64(gid, d, NULL, n, gs, gc, 1024); sink += (uint64_t)gs[3]; break;
        case 12: t.gather_i64(d, idx, n, out64); sink += (uint64_t)out64[n - 1]; break;
        case 13: sink += t.filter_i128(w, NULL, n, PQK_LT, &ca, NULL, idx); break;
        case 14: sink += t.count_i128(w, NULL, n, PQK_BETWEEN, &ca, &cb); break;
        case 15: { pqk_i128 q; t.sum_i128(w, NULL, n, &q); sink += q.lo; } break;
        case 16: { pqk_i128 q, x; t.minmax_i128(w, val, n, &q, &x); sink += q.lo + x.lo; } break;
        }
        double el = now_ns() - t0;
        if (r >= 0) ts[r] = el;
      }
      qsort(ts, reps, sizeof(double), cmpd);
      printf("{\"variant\":\"%s\",\"kernel\":\"%s\",\"n\":%zu,\"reps\":%d,\"median_ns\":%.0f,\"min_ns\":%.0f,\"max_ns\":%.0f,\"ns_per_elem\":%.4f}\n",
             variants[vk], kernels[kk], n, reps, ts[reps / 2], ts[0], ts[reps - 1], ts[reps / 2] / (double)n);
      free(ts);
    }
  }
  return sink == 42 ? 1 : 0;
}
