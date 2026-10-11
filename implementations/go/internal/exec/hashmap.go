package exec

// Open-addressing hash tables specialized for integer keys, used where Go
// maps dominated profiles (grouping by an int-class key, DISTINCT
// aggregates). Slots hold key and value side by side, so a lookup usually
// touches a single cache line; probing is linear; the load factor stays at
// most 1/2.

// fibHash spreads an integer key over the upper bits (Fibonacci hashing):
// sequential keys, the common case, land in distinct slots.
func fibHash(k uint64) uint64 { return k * 0x9E3779B97F4A7C15 }

// i64Map maps int64 keys to non-negative int32 values (group IDs).
type i64Map struct {
	slots []i64Slot
	shift uint8 // 64 - log2(len(slots))
	n     int
}

type i64Slot struct {
	key int64
	val int32 // value + 1; 0 = empty slot
}

// minMapSlots is the initial size of a table.
const minMapSlots = 64

func (m *i64Map) init(hint int) {
	size := minMapSlots
	for size < 2*hint {
		size *= 2
	}
	m.slots = make([]i64Slot, size)
	m.shift = uint8(64 - log2(size))
	m.n = 0
}

func log2(n int) int {
	l := 0
	for 1<<l < n {
		l++
	}
	return l
}

func (m *i64Map) get(k int64) (int32, bool) {
	if m.slots == nil {
		return 0, false
	}
	mask := uint64(len(m.slots) - 1)
	for i := fibHash(uint64(k)) >> m.shift; ; i = (i + 1) & mask {
		s := &m.slots[i]
		if s.val == 0 {
			return 0, false
		}
		if s.key == k {
			return s.val - 1, true
		}
	}
}

// put adds a key that is not in the table.
func (m *i64Map) put(k int64, v int32) {
	if 2*(m.n+1) > len(m.slots) {
		m.rehash()
	}
	m.n++
	m.place(k, v+1)
}

func (m *i64Map) place(k int64, v1 int32) {
	mask := uint64(len(m.slots) - 1)
	for i := fibHash(uint64(k)) >> m.shift; ; i = (i + 1) & mask {
		if s := &m.slots[i]; s.val == 0 {
			s.key, s.val = k, v1
			return
		}
	}
}

func (m *i64Map) rehash() {
	old := m.slots
	n := m.n
	m.init(max(n+1, len(old)))
	m.n = n
	for _, s := range old {
		if s.val != 0 {
			m.place(s.key, s.val)
		}
	}
}

// pairSet is a set of (group, int64 value) pairs: the values each group of
// a DISTINCT aggregate has seen.
type pairSet struct {
	slots []pairSlot
	shift uint8
	n     int
}

type pairSlot struct {
	val  int64
	g    int32
	used bool
}

// add inserts (g, v) and reports whether it was absent.
func (s *pairSet) add(g int32, v int64) bool {
	if 2*(s.n+1) > len(s.slots) {
		s.rehash()
	}
	mask := uint64(len(s.slots) - 1)
	for i := pairHash(g, v) >> s.shift; ; i = (i + 1) & mask {
		p := &s.slots[i]
		if !p.used {
			p.val, p.g, p.used = v, g, true
			s.n++
			return true
		}
		if p.val == v && p.g == g {
			return false
		}
	}
}

func pairHash(g int32, v int64) uint64 {
	return fibHash(uint64(v) ^ uint64(g)*0xC2B2AE3D27D4EB4F)
}

func (s *pairSet) rehash() {
	old := s.slots
	size := max(minMapSlots, 2*len(old))
	s.slots = make([]pairSlot, size)
	s.shift = uint8(64 - log2(size))
	mask := uint64(size - 1)
	for _, p := range old {
		if !p.used {
			continue
		}
		for i := pairHash(p.g, p.val) >> s.shift; ; i = (i + 1) & mask {
			if !s.slots[i].used {
				s.slots[i] = p
				break
			}
		}
	}
}
