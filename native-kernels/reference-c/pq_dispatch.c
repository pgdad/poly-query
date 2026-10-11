/* Runtime CPU-feature detection and dispatch for libpqkernels. */
#define _GNU_SOURCE
#include "pq_kernels_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__aarch64__)
#include <sys/auxv.h>
#ifndef HWCAP_ASIMD
#define HWCAP_ASIMD (1 << 1)
#endif
#ifndef HWCAP_SVE
#define HWCAP_SVE (1 << 22)
#endif
#endif

/* Weak references to every possible assembly symbol: a variant that is not
 * linked in (or a function it does not implement) resolves to NULL. */
#define W(v, name, ret, params) extern ret pqk_##v##_##name params __attribute__((weak));
#define WX(v) \
  W(v, filter_i64, size_t, (const int64_t *, const uint8_t *, size_t, int, int64_t, int64_t, uint32_t *)) \
  W(v, filter_i64_bitmap, size_t, (const int64_t *, const uint8_t *, size_t, int, int64_t, int64_t, uint8_t *)) \
  W(v, sum_i64, int, (const int64_t *, const uint8_t *, size_t, int64_t *)) \
  W(v, sum_f64, double, (const double *, const uint8_t *, size_t)) \
  W(v, minmax_i64, size_t, (const int64_t *, const uint8_t *, size_t, int64_t *, int64_t *)) \
  W(v, minmax_f64, size_t, (const double *, const uint8_t *, size_t, double *, double *)) \
  W(v, count_i64, size_t, (const int64_t *, const uint8_t *, size_t, int, int64_t, int64_t)) \
  W(v, bitmap_and, void, (const uint8_t *, const uint8_t *, uint8_t *, size_t)) \
  W(v, bitmap_or, void, (const uint8_t *, const uint8_t *, uint8_t *, size_t)) \
  W(v, bitmap_andnot, void, (const uint8_t *, const uint8_t *, uint8_t *, size_t)) \
  W(v, bitmap_popcount, size_t, (const uint8_t *, size_t)) \
  W(v, hash_i64, void, (const int64_t *, size_t, uint64_t, uint64_t *)) \
  W(v, compare_i64, size_t, (const int64_t *, const int64_t *, size_t, int, uint8_t *)) \
  W(v, compare_fixed, void, (const uint8_t *, const uint8_t *, size_t, size_t, int8_t *)) \
  W(v, group_sum_i64, int, (const uint32_t *, const int64_t *, const uint8_t *, size_t, int64_t *, int64_t *, size_t)) \
  W(v, gather_i64, void, (const int64_t *, const uint32_t *, size_t, int64_t *)) \
  W(v, filter_i128, size_t, (const pqk_i128 *, const uint8_t *, size_t, int, const pqk_i128 *, const pqk_i128 *, uint32_t *)) \
  W(v, count_i128, size_t, (const pqk_i128 *, const uint8_t *, size_t, int, const pqk_i128 *, const pqk_i128 *)) \
  W(v, sum_i128, int, (const pqk_i128 *, const uint8_t *, size_t, pqk_i128 *)) \
  W(v, minmax_i128, size_t, (const pqk_i128 *, const uint8_t *, size_t, pqk_i128 *, pqk_i128 *))
#define WXV(v) WX(v)
PQK_VARIANTS(WXV)

static void fill_reference(pqk_table *t) {
#define REF(name, ret, params, args) t->name = pqk_ref_##name;
  PQK_KERNELS(REF)
}

int pqk_variant_table(const char *variant, pqk_table *t) {
  fill_reference(t);
  if (strcmp(variant, "reference") == 0) return PQK_NKERNELS;
  int provided = 0;
#define TAKE(v, name) if (pqk_##v##_##name) { t->name = pqk_##v##_##name; provided++; }
#define TAKE_ALL(v) \
  TAKE(v, filter_i64) TAKE(v, filter_i64_bitmap) TAKE(v, sum_i64) TAKE(v, sum_f64) TAKE(v, minmax_i64) \
  TAKE(v, minmax_f64) TAKE(v, count_i64) TAKE(v, bitmap_and) TAKE(v, bitmap_or) TAKE(v, bitmap_andnot) \
  TAKE(v, bitmap_popcount) TAKE(v, hash_i64) TAKE(v, compare_i64) TAKE(v, compare_fixed) \
  TAKE(v, group_sum_i64) TAKE(v, gather_i64) \
  TAKE(v, filter_i128) TAKE(v, count_i128) TAKE(v, sum_i128) TAKE(v, minmax_i128)
#define TRY(v) if (strcmp(variant, #v) == 0) { TAKE_ALL(v) return provided; }
  PQK_VARIANTS(TRY)
  return 0;
}

int pqk_cpu_supports(const char *variant) {
#if defined(__x86_64__)
  __builtin_cpu_init();
  if (!strcmp(variant, "x86_scalar")) return 1;
  if (!strcmp(variant, "x86_avx2")) return __builtin_cpu_supports("avx2") && __builtin_cpu_supports("bmi2") && __builtin_cpu_supports("popcnt");
  if (!strcmp(variant, "x86_avx512")) return __builtin_cpu_supports("avx512f") && __builtin_cpu_supports("avx512bw") &&
                                             __builtin_cpu_supports("avx512vl") && __builtin_cpu_supports("avx512dq");
#elif defined(__aarch64__)
  unsigned long hw = getauxval(AT_HWCAP);
  if (!strcmp(variant, "a64_scalar")) return 1;
  if (!strcmp(variant, "a64_neon")) return (hw & HWCAP_ASIMD) != 0;
  if (!strcmp(variant, "a64_sve")) return (hw & HWCAP_SVE) != 0;
#endif
  return !strcmp(variant, "reference");
}

static pqk_table active;
static const char *active_name = "reference";
static char available[256];
static int initialized;

static const char *alias(const char *name) {
  /* Public short names map to the architecture-specific variant names. */
  static const char *const map[][3] = {
    {"scalar", "x86_scalar", "a64_scalar"}, {"avx2", "x86_avx2", NULL}, {"avx512", "x86_avx512", NULL},
    {"neon", NULL, "a64_neon"}, {"sve", NULL, "a64_sve"}};
  for (size_t i = 0; i < sizeof map / sizeof map[0]; i++) {
    if (!strcmp(name, map[i][0])) {
#if defined(__x86_64__)
      return map[i][1] ? map[i][1] : name;
#else
      return map[i][2] ? map[i][2] : name;
#endif
    }
  }
  return name;
}

int pqk_set_variant(const char *name) {
  const char *v = alias(name);
  pqk_table t;
  if (!pqk_cpu_supports(v)) return PQK_EINVAL;
  if (strcmp(v, "reference") && pqk_variant_table(v, &t) == 0) return PQK_EINVAL;
  if (!strcmp(v, "reference")) pqk_variant_table("reference", &t);
  active = t;
  active_name = v;
  return PQK_OK;
}

int pqk_init(void) {
  if (initialized) return PQK_OK;
  initialized = 1;
  pqk_variant_table("reference", &active);
  available[0] = 0;
  strcat(available, "reference");
  const char *best = NULL;
  pqk_table t;
#define AVAIL(v) if (pqk_cpu_supports(#v) && pqk_variant_table(#v, &t) > 0) { \
    strcat(available, "," #v); if (!best) best = #v; }
  PQK_VARIANTS(AVAIL)
  const char *env = getenv("PQ_KERNELS_VARIANT");
  if (env && *env && pqk_set_variant(env) == PQK_OK) return PQK_OK;
  if (best) pqk_set_variant(best);
  return PQK_OK;
}

int pqk_abi_version(void) { return PQK_ABI_VERSION; }
int pqk_abi_revision(void) { return PQK_ABI_REVISION; }
const char *pqk_variant(void) { pqk_init(); return active_name; }
const char *pqk_available_variants(void) { pqk_init(); return available; }

/* Public entry points dispatch through the active table. */
#define PUB(name, ret, params, args) ret pqk_##name params { if (!initialized) pqk_init(); return active.name args; }
PQK_KERNELS(PUB)
