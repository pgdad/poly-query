//go:build cgo && unix

package native

/*
#cgo linux LDFLAGS: -ldl
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

// Function table of one loaded libpqkernels (prototypes of pq_kernels.h).
typedef struct {
	void *handle;
	int (*abi_version)(void);
	int (*init)(void);
	const char *(*variant)(void);
	const char *(*available_variants)(void);
	size_t (*filter_i64)(const int64_t *, const uint8_t *, size_t, int, int64_t, int64_t, uint32_t *);
	size_t (*filter_i64_bitmap)(const int64_t *, const uint8_t *, size_t, int, int64_t, int64_t, uint8_t *);
	int (*sum_i64)(const int64_t *, const uint8_t *, size_t, int64_t *);
	double (*sum_f64)(const double *, const uint8_t *, size_t);
	size_t (*minmax_i64)(const int64_t *, const uint8_t *, size_t, int64_t *, int64_t *);
	size_t (*minmax_f64)(const double *, const uint8_t *, size_t, double *, double *);
	size_t (*count_i64)(const int64_t *, const uint8_t *, size_t, int, int64_t, int64_t);
	void (*bitmap_and)(const uint8_t *, const uint8_t *, uint8_t *, size_t);
	void (*bitmap_or)(const uint8_t *, const uint8_t *, uint8_t *, size_t);
	void (*bitmap_andnot)(const uint8_t *, const uint8_t *, uint8_t *, size_t);
	size_t (*bitmap_popcount)(const uint8_t *, size_t);
	void (*hash_i64)(const int64_t *, size_t, uint64_t, uint64_t *);
	size_t (*compare_i64)(const int64_t *, const int64_t *, size_t, int, uint8_t *);
	void (*compare_fixed)(const uint8_t *, const uint8_t *, size_t, size_t, int8_t *);
	int (*group_sum_i64)(const uint32_t *, const int64_t *, const uint8_t *, size_t, int64_t *, int64_t *, size_t);
	void (*gather_i64)(const int64_t *, const uint32_t *, size_t, int64_t *);
} pq_lib;

#define PQ_SYM(field, name) \
	if (!(*(void **)(&l->field) = dlsym(l->handle, name))) { *missing = name; goto fail; }

// pq_open loads the library at path and resolves every kernel. On failure
// it returns NULL and sets *err (dlerror text) or *missing (symbol name).
static pq_lib *pq_open(const char *path, const char **err, const char **missing) {
	*err = NULL;
	*missing = NULL;
	pq_lib *l = calloc(1, sizeof(pq_lib));
	if (!l) { *err = "out of memory"; return NULL; }
	l->handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!l->handle) { *err = dlerror(); free(l); return NULL; }
	PQ_SYM(abi_version, "pqk_abi_version")
	PQ_SYM(init, "pqk_init")
	PQ_SYM(variant, "pqk_variant")
	PQ_SYM(available_variants, "pqk_available_variants")
	PQ_SYM(filter_i64, "pqk_filter_i64")
	PQ_SYM(filter_i64_bitmap, "pqk_filter_i64_bitmap")
	PQ_SYM(sum_i64, "pqk_sum_i64")
	PQ_SYM(sum_f64, "pqk_sum_f64")
	PQ_SYM(minmax_i64, "pqk_minmax_i64")
	PQ_SYM(minmax_f64, "pqk_minmax_f64")
	PQ_SYM(count_i64, "pqk_count_i64")
	PQ_SYM(bitmap_and, "pqk_bitmap_and")
	PQ_SYM(bitmap_or, "pqk_bitmap_or")
	PQ_SYM(bitmap_andnot, "pqk_bitmap_andnot")
	PQ_SYM(bitmap_popcount, "pqk_bitmap_popcount")
	PQ_SYM(hash_i64, "pqk_hash_i64")
	PQ_SYM(compare_i64, "pqk_compare_i64")
	PQ_SYM(compare_fixed, "pqk_compare_fixed")
	PQ_SYM(group_sum_i64, "pqk_group_sum_i64")
	PQ_SYM(gather_i64, "pqk_gather_i64")
	return l;
fail:
	dlclose(l->handle);
	free(l);
	return NULL;
}

static int pq_abi_version(pq_lib *l) { return l->abi_version(); }
static int pq_init(pq_lib *l) { return l->init(); }
static const char *pq_variant(pq_lib *l) { return l->variant(); }
static const char *pq_available_variants(pq_lib *l) { return l->available_variants(); }

static size_t pq_filter_i64(pq_lib *l, const int64_t *d, const uint8_t *v, size_t n, int op,
		int64_t a, int64_t b, uint32_t *out) {
	return l->filter_i64(d, v, n, op, a, b, out);
}
static size_t pq_filter_i64_bitmap(pq_lib *l, const int64_t *d, const uint8_t *v, size_t n, int op,
		int64_t a, int64_t b, uint8_t *out) {
	return l->filter_i64_bitmap(d, v, n, op, a, b, out);
}
static int pq_sum_i64(pq_lib *l, const int64_t *d, const uint8_t *v, size_t n, int64_t *out) {
	return l->sum_i64(d, v, n, out);
}
static double pq_sum_f64(pq_lib *l, const double *d, const uint8_t *v, size_t n) {
	return l->sum_f64(d, v, n);
}
static size_t pq_minmax_i64(pq_lib *l, const int64_t *d, const uint8_t *v, size_t n, int64_t *mn, int64_t *mx) {
	return l->minmax_i64(d, v, n, mn, mx);
}
static size_t pq_minmax_f64(pq_lib *l, const double *d, const uint8_t *v, size_t n, double *mn, double *mx) {
	return l->minmax_f64(d, v, n, mn, mx);
}
static size_t pq_count_i64(pq_lib *l, const int64_t *d, const uint8_t *v, size_t n, int op, int64_t a, int64_t b) {
	return l->count_i64(d, v, n, op, a, b);
}
static void pq_bitmap_and(pq_lib *l, const uint8_t *a, const uint8_t *b, uint8_t *out, size_t n) {
	l->bitmap_and(a, b, out, n);
}
static void pq_bitmap_or(pq_lib *l, const uint8_t *a, const uint8_t *b, uint8_t *out, size_t n) {
	l->bitmap_or(a, b, out, n);
}
static void pq_bitmap_andnot(pq_lib *l, const uint8_t *a, const uint8_t *b, uint8_t *out, size_t n) {
	l->bitmap_andnot(a, b, out, n);
}
static size_t pq_bitmap_popcount(pq_lib *l, const uint8_t *bits, size_t nbits) {
	return l->bitmap_popcount(bits, nbits);
}
static void pq_hash_i64(pq_lib *l, const int64_t *d, size_t n, uint64_t seed, uint64_t *out) {
	l->hash_i64(d, n, seed, out);
}
static size_t pq_compare_i64(pq_lib *l, const int64_t *a, const int64_t *b, size_t n, int op, uint8_t *out) {
	return l->compare_i64(a, b, n, op, out);
}
static void pq_compare_fixed(pq_lib *l, const uint8_t *a, const uint8_t *b, size_t w, size_t n, int8_t *out) {
	l->compare_fixed(a, b, w, n, out);
}
static int pq_group_sum_i64(pq_lib *l, const uint32_t *g, const int64_t *v, const uint8_t *valid, size_t n,
		int64_t *sums, int64_t *counts, size_t ngroups) {
	return l->group_sum_i64(g, v, valid, n, sums, counts, ngroups);
}
static void pq_gather_i64(pq_lib *l, const int64_t *d, const uint32_t *idx, size_t m, int64_t *out) {
	l->gather_i64(d, idx, m, out);
}
// The kernels neither retain their arguments nor call back into Go, so Go
// memory is passed without escaping it to the heap.
#cgo noescape pq_filter_i64
#cgo nocallback pq_filter_i64
#cgo noescape pq_filter_i64_bitmap
#cgo nocallback pq_filter_i64_bitmap
#cgo noescape pq_sum_i64
#cgo nocallback pq_sum_i64
#cgo noescape pq_sum_f64
#cgo nocallback pq_sum_f64
#cgo noescape pq_minmax_i64
#cgo nocallback pq_minmax_i64
#cgo noescape pq_minmax_f64
#cgo nocallback pq_minmax_f64
#cgo noescape pq_count_i64
#cgo nocallback pq_count_i64
#cgo noescape pq_bitmap_and
#cgo nocallback pq_bitmap_and
#cgo noescape pq_bitmap_or
#cgo nocallback pq_bitmap_or
#cgo noescape pq_bitmap_andnot
#cgo nocallback pq_bitmap_andnot
#cgo noescape pq_bitmap_popcount
#cgo nocallback pq_bitmap_popcount
#cgo noescape pq_hash_i64
#cgo nocallback pq_hash_i64
#cgo noescape pq_compare_i64
#cgo nocallback pq_compare_i64
#cgo noescape pq_compare_fixed
#cgo nocallback pq_compare_fixed
#cgo noescape pq_group_sum_i64
#cgo nocallback pq_group_sum_i64
#cgo noescape pq_gather_i64
#cgo nocallback pq_gather_i64
*/
import "C"

import (
	"fmt"
	"unsafe"
)

// Supported reports whether this build can load the native library.
func Supported() bool { return true }

// Lib is a loaded kernel library. It is safe for concurrent use.
type Lib struct {
	l       *C.pq_lib
	path    string
	variant string
}

// Load opens libpqkernels at path, checks its ABI version and initializes
// its runtime dispatch (which honours PQ_KERNELS_VARIANT).
func Load(path string) (*Lib, error) {
	if !littleEndian() {
		return nil, fmt.Errorf("native kernels require a little-endian host")
	}
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	var cerr, missing *C.char
	l := C.pq_open(cpath, &cerr, &missing)
	if l == nil {
		if missing != nil {
			return nil, fmt.Errorf("%s: missing symbol %s", path, C.GoString(missing))
		}
		return nil, fmt.Errorf("%s", C.GoString(cerr))
	}
	if v := int(C.pq_abi_version(l)); v != ABIVersion {
		return nil, fmt.Errorf("%s: ABI version %d, want %d", path, v, ABIVersion)
	}
	if st := C.pq_init(l); st != 0 {
		return nil, fmt.Errorf("%s: pqk_init failed with status %d", path, int(st))
	}
	return &Lib{l: l, path: path, variant: C.GoString(C.pq_variant(l))}, nil
}

// Path returns the path the library was loaded from.
func (lib *Lib) Path() string { return lib.path }

// Variant returns the active kernel variant (e.g. "avx2").
func (lib *Lib) Variant() string { return lib.variant }

// AvailableVariants returns the variants usable on this CPU.
func (lib *Lib) AvailableVariants() string { return C.GoString(C.pq_available_variants(lib.l)) }

func ptr[T any](s []T) *T {
	if len(s) == 0 {
		return nil
	}
	return &s[0]
}

func i64p(s []int64) *C.int64_t   { return (*C.int64_t)(unsafe.Pointer(ptr(s))) }
func f64p(s []float64) *C.double  { return (*C.double)(unsafe.Pointer(ptr(s))) }
func u8p(s []byte) *C.uint8_t     { return (*C.uint8_t)(unsafe.Pointer(ptr(s))) }
func u32p(s []uint32) *C.uint32_t { return (*C.uint32_t)(unsafe.Pointer(ptr(s))) }
func u64p(s []uint64) *C.uint64_t { return (*C.uint64_t)(unsafe.Pointer(ptr(s))) }

// FilterI64 writes the ascending indices i < len(data) of valid rows where
// op(data[i], a, b) holds into out (capacity ≥ len(data)) and returns their
// number.
func (lib *Lib) FilterI64(data []int64, valid []byte, op Op, a, b int64, out []uint32) int {
	n := len(data)
	checkValidity(valid, n)
	checkLen("index", len(out), n)
	return int(C.pq_filter_i64(lib.l, i64p(data), u8p(valid), C.size_t(n), C.int(op),
		C.int64_t(a), C.int64_t(b), u32p(out)))
}

// FilterI64Bitmap is FilterI64 producing a bitmap (trailing bits zeroed);
// it returns the number of set bits.
func (lib *Lib) FilterI64Bitmap(data []int64, valid []byte, op Op, a, b int64, out []byte) int {
	n := len(data)
	checkValidity(valid, n)
	checkLen("bitmap", len(out), BitmapBytes(n))
	return int(C.pq_filter_i64_bitmap(lib.l, i64p(data), u8p(valid), C.size_t(n), C.int(op),
		C.int64_t(a), C.int64_t(b), u8p(out)))
}

// SumI64 sums the valid values exactly; ok is false if the exact sum is
// outside the int64 range.
func (lib *Lib) SumI64(data []int64, valid []byte) (sum int64, ok bool) {
	checkValidity(valid, len(data))
	var s C.int64_t
	st := Status(C.pq_sum_i64(lib.l, i64p(data), u8p(valid), C.size_t(len(data)), &s))
	return int64(s), st == OK
}

// SumF64 sums the valid doubles (lane-wise reassociated; not bit-identical
// to sequential summation).
func (lib *Lib) SumF64(data []float64, valid []byte) float64 {
	checkValidity(valid, len(data))
	return float64(C.pq_sum_f64(lib.l, f64p(data), u8p(valid), C.size_t(len(data))))
}

// MinMaxI64 returns the number of valid values and, if positive, their
// minimum and maximum.
func (lib *Lib) MinMaxI64(data []int64, valid []byte) (count int, lo, hi int64) {
	checkValidity(valid, len(data))
	var mn, mx C.int64_t
	count = int(C.pq_minmax_i64(lib.l, i64p(data), u8p(valid), C.size_t(len(data)), &mn, &mx))
	return count, int64(mn), int64(mx)
}

// MinMaxF64 is MinMaxI64 for finite doubles.
func (lib *Lib) MinMaxF64(data []float64, valid []byte) (count int, lo, hi float64) {
	checkValidity(valid, len(data))
	var mn, mx C.double
	count = int(C.pq_minmax_f64(lib.l, f64p(data), u8p(valid), C.size_t(len(data)), &mn, &mx))
	return count, float64(mn), float64(mx)
}

// CountI64 returns the number of valid rows satisfying the predicate.
func (lib *Lib) CountI64(data []int64, valid []byte, op Op, a, b int64) int {
	checkValidity(valid, len(data))
	return int(C.pq_count_i64(lib.l, i64p(data), u8p(valid), C.size_t(len(data)), C.int(op),
		C.int64_t(a), C.int64_t(b)))
}

// BitmapAnd sets out = a & b over len(out) bytes (out may alias a or b).
func (lib *Lib) BitmapAnd(a, b, out []byte) {
	checkLen("bitmap", min(len(a), len(b)), len(out))
	C.pq_bitmap_and(lib.l, u8p(a), u8p(b), u8p(out), C.size_t(len(out)))
}

// BitmapOr sets out = a | b over len(out) bytes.
func (lib *Lib) BitmapOr(a, b, out []byte) {
	checkLen("bitmap", min(len(a), len(b)), len(out))
	C.pq_bitmap_or(lib.l, u8p(a), u8p(b), u8p(out), C.size_t(len(out)))
}

// BitmapAndNot sets out = a &^ b over len(out) bytes.
func (lib *Lib) BitmapAndNot(a, b, out []byte) {
	checkLen("bitmap", min(len(a), len(b)), len(out))
	C.pq_bitmap_andnot(lib.l, u8p(a), u8p(b), u8p(out), C.size_t(len(out)))
}

// Popcount returns the number of set bits among the first nbits bits.
func (lib *Lib) Popcount(bits []byte, nbits int) int {
	checkLen("bitmap", len(bits), BitmapBytes(nbits))
	return int(C.pq_bitmap_popcount(lib.l, u8p(bits), C.size_t(nbits)))
}

// HashI64 sets out[i] = fmix64(uint64(data[i]) ^ seed).
func (lib *Lib) HashI64(data []int64, seed uint64, out []uint64) {
	checkLen("hash", len(out), len(data))
	C.pq_hash_i64(lib.l, i64p(data), C.size_t(len(data)), C.uint64_t(seed), u64p(out))
}

// CompareI64 sets bit i of out to op(a[i], b[i]) for i < len(a) (op in
// EQ…GE) and returns the number of set bits.
func (lib *Lib) CompareI64(a, b []int64, op Op, out []byte) int {
	n := len(a)
	checkLen("operand", len(b), n)
	checkLen("bitmap", len(out), BitmapBytes(n))
	return int(C.pq_compare_i64(lib.l, i64p(a), i64p(b), C.size_t(n), C.int(op), u8p(out)))
}

// CompareFixed compares n records of width bytes lexicographically:
// out[i] = -1, 0, 1.
func (lib *Lib) CompareFixed(a, b []byte, width int, out []int8) {
	n := len(out)
	checkLen("record", min(len(a), len(b)), n*width)
	C.pq_compare_fixed(lib.l, u8p(a), u8p(b), C.size_t(width), C.size_t(n),
		(*C.int8_t)(unsafe.Pointer(ptr(out))))
}

// GroupSumI64 adds values[i] to sums[gids[i]] (and 1 to counts[gids[i]],
// if counts is non-nil) for valid rows i < len(gids), with wrapping
// arithmetic. It returns Invalid (nothing updated) for a group ID out of
// range, Overflow if some addition may have wrapped (the caller must
// recompute exactly) and OK if every sum is exact.
func (lib *Lib) GroupSumI64(gids []uint32, values []int64, valid []byte, sums, counts []int64) Status {
	n := len(gids)
	checkLen("value", len(values), n)
	checkValidity(valid, n)
	if counts != nil {
		checkLen("count", len(counts), len(sums))
	}
	return Status(C.pq_group_sum_i64(lib.l, u32p(gids), i64p(values), u8p(valid), C.size_t(n),
		i64p(sums), i64p(counts), C.size_t(len(sums))))
}

// GatherI64 sets out[j] = data[idx[j]] for j < len(idx). Every index must
// be less than len(data) (not checked: callers pass selection vectors).
func (lib *Lib) GatherI64(data []int64, idx []uint32, out []int64) {
	checkLen("gather", len(out), len(idx))
	C.pq_gather_i64(lib.l, i64p(data), u32p(idx), C.size_t(len(idx)), i64p(out))
}
