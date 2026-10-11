package exec

import (
	"hash/maphash"
	"math"
	"math/bits"

	"polyquery/internal/types"
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

// tupleGroupMap maps keys of several columns (or a single FLOAT64 key) to
// groups. Slots hold the tuple's hash (see tupleHasher); keys are compared
// by the caller on equal hashes.
type tupleGroupMap struct {
	slots []tupleGroupSlot
	used  int
}

type tupleGroupSlot struct {
	h  uint64
	g1 int32 // group + 1; 0 = empty
}

func newTupleGroupMap() *tupleGroupMap {
	return &tupleGroupMap{slots: make([]tupleGroupSlot, 64)}
}

// find returns the group with hash h for which eq holds, and whether there
// is one; if not, slot is where it would be inserted (valid until the next
// insert).
func (m *tupleGroupMap) find(h uint64, eq func(g int32) bool) (g int32, slot int, ok bool) {
	mask := len(m.slots) - 1
	for i := int(h) & mask; ; i = (i + 1) & mask {
		sl := &m.slots[i]
		if sl.g1 == 0 {
			return 0, i, false
		}
		if sl.h == h && eq(sl.g1-1) {
			return sl.g1 - 1, i, true
		}
	}
}

// insert stores a new group in the slot returned by find.
func (m *tupleGroupMap) insert(slot int, h uint64, g int32) {
	m.slots[slot] = tupleGroupSlot{h: h, g1: g + 1}
	m.used++
	if 2*m.used > len(m.slots) {
		old := m.slots
		m.slots = make([]tupleGroupSlot, 2*len(old))
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
}

// tupleHasher hashes key tuples, from values or from rows of key vectors
// (with the hashes of dictionary entries cached per key column).
type tupleHasher struct {
	classes []vclass
	dicts   [][]string // per key column: dictionary of the cached hashes
	hashes  [][]uint64
	known   [][]bool
}

const nullKeyHash = 0x51ed270b27a3b2f1

// valueHash hashes one key value; equal values (as compared by
// sameKeyValue) hash equally.
func valueHash(v types.Value, c vclass) uint64 {
	if v.Null {
		return nullKeyHash
	}
	switch c {
	case vInt:
		return mix64(uint64(v.I))
	case vFloat:
		return mix64(floatKeyBits(v.F) ^ 0x2545F4914F6CDD1D)
	case vWide:
		w := v.Wide()
		return mix64(w.Lo ^ mix64(uint64(w.Hi)))
	}
	return strKeyHash(v.S)
}

// floatKeyBits is the bit pattern identifying a FLOAT64 key (-0 = 0, as in
// appendKey).
func floatKeyBits(f float64) uint64 {
	if f == 0 {
		f = 0
	}
	return math.Float64bits(f)
}

func combineHash(h, c uint64) uint64 { return mix64(h*0x9E3779B97F4A7C15 + c) }

// valuesHash hashes a key row.
func (th *tupleHasher) valuesHash(key types.Row) uint64 {
	h := uint64(len(key))
	for k, v := range key {
		h = combineHash(h, valueHash(v, th.classes[k]))
	}
	return h
}

// rowHash hashes the key of row i (equal to valuesHash of its values).
func (th *tupleHasher) rowHash(keys []*Vec, i int) uint64 {
	h := uint64(len(keys))
	for k, v := range keys {
		var c uint64
		switch {
		case v.isNull(i):
			c = nullKeyHash
		case v.Dict != nil && th.classes[k] == vStr:
			c = th.dictHash(k, v, i)
		default:
			c = valueHash(v.value(i, th.classes[k]), th.classes[k])
		}
		h = combineHash(h, c)
	}
	return h
}

// dictHash returns the hash of row i's dictionary entry, cached per entry.
func (th *tupleHasher) dictHash(k int, v *Vec, i int) uint64 {
	if th.dicts == nil {
		n := len(th.classes)
		th.dicts, th.hashes, th.known = make([][]string, n), make([][]uint64, n), make([][]bool, n)
	}
	if !sameDict(th.dicts[k], v.Dict) {
		th.dicts[k] = v.Dict
		th.hashes[k] = grow(th.hashes[k], len(v.Dict))
		th.known[k] = grow(th.known[k], len(v.Dict))
		clear(th.known[k])
	}
	c := v.Codes[i]
	if !th.known[k][c] {
		th.hashes[k][c] = strKeyHash(v.Dict[c])
		th.known[k][c] = true
	}
	return th.hashes[k][c]
}

// sameKeyValue reports whether two values of one key column are the same
// key (as their canonical encodings, appendKey, would be: a column has one
// type, so DECIMALs share their scale).
func sameKeyValue(a, b types.Value, c vclass) bool {
	if a.Null || b.Null {
		return a.Null == b.Null
	}
	switch c {
	case vInt:
		return a.I == b.I
	case vFloat:
		return floatKeyBits(a.F) == floatKeyBits(b.F)
	case vWide:
		return a.Wide() == b.Wide()
	}
	return a.S == b.S
}
