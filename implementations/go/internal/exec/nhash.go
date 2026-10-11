package exec

import (
	"unsafe"

	"polyquery/internal/native"
)

// Native hashing and gathering helpers (option native: true).
//
// GROUP BY tables keyed by a single int-class column hash the keys of a
// whole batch at once with pqk_hash_i64 (MurmurHash3's fmix64 finalizer)
// and probe an open-addressing table with the precomputed hashes; single
// lookups outside batches (merging partial tables) use the identical Go
// fmix64. Hashes only choose slots — group numbering follows first
// appearance — so results are those of the Go code paths.
//
// The vectorized hash join keeps its multiplicative hash even with native
// kernels: measured on the 1m datasets, fmix64's avalanche turns the
// clustered (often sequential) join keys into random bucket accesses,
// which made probing about 1.6x slower than the locality-preserving
// multiplicative hash. Joins use pqk_gather_i64 for probe columns instead.

// nativeHashSeed seeds pqk_hash_i64.
const nativeHashSeed = 0x9E3779B97F4A7C15

// fmix64 is the Go equivalent of pqk_hash_i64 for one key.
func fmix64(k int64) uint64 {
	h := uint64(k) ^ nativeHashSeed
	h ^= h >> 33
	h *= 0xff51afd7ed558ccd
	h ^= h >> 33
	h *= 0xc4ceb9fe1a85ec53
	h ^= h >> 33
	return h
}

// nativeIntMap is an open-addressing (linear probing) hash table from
// int64 keys to group IDs.
type nativeIntMap struct {
	lib    *native.Lib
	slots  []int32 // entry index + 1; 0 = empty
	keys   []int64 // per entry
	vals   []int32 // per entry
	mask   uint64
	hashes []uint64 // batch hash buffer
}

func newNativeIntMap(lib *native.Lib) *nativeIntMap {
	return &nativeIntMap{lib: lib, slots: make([]int32, 64), mask: 63}
}

// hashBatch hashes keys with the kernel (valid until the next call).
func (m *nativeIntMap) hashBatch(keys []int64) []uint64 {
	m.hashes = grow(m.hashes, len(keys))
	m.lib.HashI64(keys, nativeHashSeed, m.hashes)
	return m.hashes
}

func (m *nativeIntMap) get(k int64, h uint64) (int32, bool) {
	for i := h & m.mask; ; i = (i + 1) & m.mask {
		s := m.slots[i]
		if s == 0 {
			return 0, false
		}
		if m.keys[s-1] == k {
			return m.vals[s-1], true
		}
	}
}

// put adds a key that is not in the table.
func (m *nativeIntMap) put(k int64, h uint64, g int32) {
	if 2*(len(m.keys)+1) > len(m.slots) {
		m.rehash()
	}
	m.keys = append(m.keys, k)
	m.vals = append(m.vals, g)
	m.place(h, int32(len(m.keys)))
}

func (m *nativeIntMap) place(h uint64, s int32) {
	for i := h & m.mask; ; i = (i + 1) & m.mask {
		if m.slots[i] == 0 {
			m.slots[i] = s
			return
		}
	}
}

// rehash doubles the slot array (load factor ≤ 1/2).
func (m *nativeIntMap) rehash() {
	m.slots = make([]int32, 2*len(m.slots))
	m.mask = uint64(len(m.slots) - 1)
	hashes := make([]uint64, len(m.keys))
	m.lib.HashI64(m.keys, nativeHashSeed, hashes)
	for e, h := range hashes {
		m.place(h, int32(e+1))
	}
}

// asUint32 views non-negative int32 indices as the kernels' uint32.
func asUint32(idx []int32) []uint32 {
	return unsafe.Slice((*uint32)(unsafe.Pointer(unsafe.SliceData(idx))), len(idx))
}

// gatherInts sets out[o] = data[idx[o]] for non-decreasing indices idx,
// with pqk_gather_i64 when lib is non-nil.
func gatherInts(lib *native.Lib, data []int64, idx []int32, out []int64) {
	if lib != nil && len(idx) > 0 && idx[0] >= 0 && int(idx[len(idx)-1]) < len(data) {
		lib.GatherI64(data, asUint32(idx), out[:len(idx)])
		return
	}
	for o, i := range idx {
		out[o] = data[i]
	}
}

// activeMask packs the rows of sel (nil: 0..n-1) that are not NULL into
// an LSB-first bitmap in buf.
func activeMask(buf []byte, n int, sel []int32, nulls []bool) []byte {
	buf = grow(buf, native.BitmapBytes(n))
	clear(buf)
	if sel == nil {
		for i, isNull := range nulls[:n] {
			if !isNull {
				buf[i>>3] |= 1 << (i & 7)
			}
		}
		return buf
	}
	for _, i := range sel {
		if nulls == nil || !nulls[i] {
			buf[i>>3] |= 1 << (i & 7)
		}
	}
	return buf
}
