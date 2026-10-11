package exec

import (
	"hash/maphash"
	"math/bits"
)

// Open-addressing (linear probing, load factor ≤ 1/2) hash tables from a
// single grouping key to its group ID, used by hash aggregation instead of
// Go maps: slots hold the key (or its hash) next to the group, so most
// probes touch one cache line, and STRING keys are hashed once per row —
// the hash is kept per group for merging and partitioning partial tables.

// intGroupMap maps INT-class keys to groups.
type intGroupMap struct {
	slots []intGroupSlot
	shift uint8 // 64 - log2(len(slots))
	used  int
}

type intGroupSlot struct {
	key int64
	g1  int32 // group + 1; 0 = empty
}

// intSlotHash is Fibonacci hashing (the top bits select the slot).
func intSlotHash(k int64) uint64 { return uint64(k) * 0x9E3779B97F4A7C15 }

func newIntGroupMap() *intGroupMap {
	return &intGroupMap{slots: make([]intGroupSlot, 64), shift: 64 - 6}
}

// find returns the group of k and whether it exists; if not, slot is
// where it would be inserted (valid until the next insert).
func (m *intGroupMap) find(k int64) (g int32, slot int, ok bool) {
	mask := len(m.slots) - 1
	for i := int(intSlotHash(k) >> m.shift); ; i = (i + 1) & mask {
		s := &m.slots[i]
		if s.g1 == 0 {
			return 0, i, false
		}
		if s.key == k {
			return s.g1 - 1, i, true
		}
	}
}

// insert stores a new key in the slot returned by find.
func (m *intGroupMap) insert(slot int, k int64, g int32) {
	m.slots[slot] = intGroupSlot{key: k, g1: g + 1}
	m.used++
	if 2*m.used > len(m.slots) {
		m.rehash()
	}
}

func (m *intGroupMap) rehash() {
	old := m.slots
	m.slots = make([]intGroupSlot, 2*len(old))
	m.shift = uint8(64 - bits.TrailingZeros(uint(len(m.slots))))
	mask := len(m.slots) - 1
	for _, s := range old {
		if s.g1 == 0 {
			continue
		}
		i := int(intSlotHash(s.key) >> m.shift)
		for m.slots[i].g1 != 0 {
			i = (i + 1) & mask
		}
		m.slots[i] = s
	}
}

// strGroupMap maps STRING keys to groups. Slots hold the key's hash (they
// contain no pointers, so the garbage collector does not scan them); the
// keys are kept per group and compared only on equal hashes.
type strGroupMap struct {
	slots []strGroupSlot
	keys  []string // per group
	used  int
}

type strGroupSlot struct {
	h  uint64
	g1 int32 // group + 1; 0 = empty
}

// strKeySeed seeds STRING key hashes; it is shared by all tables so that
// partial tables can be merged by hash.
var strKeySeed = maphash.MakeSeed()

func strKeyHash(s string) uint64 { return maphash.String(strKeySeed, s) }

func newStrGroupMap() *strGroupMap {
	return &strGroupMap{slots: make([]strGroupSlot, 64)}
}

// find returns the group of s (hash h) and whether it exists; if not, slot
// is where it would be inserted (valid until the next insert).
func (m *strGroupMap) find(s string, h uint64) (g int32, slot int, ok bool) {
	mask := len(m.slots) - 1
	for i := int(h) & mask; ; i = (i + 1) & mask {
		sl := &m.slots[i]
		if sl.g1 == 0 {
			return 0, i, false
		}
		if sl.h == h && m.keys[sl.g1-1] == s {
			return sl.g1 - 1, i, true
		}
	}
}

// insert stores a new key in the slot returned by find.
func (m *strGroupMap) insert(slot int, s string, h uint64, g int32) {
	m.slots[slot] = strGroupSlot{h: h, g1: g + 1}
	m.keys = growZero(m.keys, int(g)+1)
	m.keys[g] = s
	m.used++
	if 2*m.used > len(m.slots) {
		m.rehash()
	}
}

func (m *strGroupMap) rehash() {
	old := m.slots
	m.slots = make([]strGroupSlot, 2*len(old))
	mask := len(m.slots) - 1
	for _, s := range old {
		if s.g1 == 0 {
			continue
		}
		i := int(s.h) & mask
		for m.slots[i].g1 != 0 {
			i = (i + 1) & mask
		}
		m.slots[i] = s
	}
}
