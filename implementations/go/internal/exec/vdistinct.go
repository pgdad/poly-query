package exec

import (
	"hash/maphash"
	"sync"

	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// distinctState computes COUNT, SUM and AVG(DISTINCT x) for INT-class
// (BOOLEAN, INT64, narrow DECIMAL, DATE, TIMESTAMP) and STRING arguments.
// All groups share one open-addressing hash set of (group, value) pairs
// whose entries are kept in insertion order; COUNT reads a per-group
// counter, SUM/AVG feed each group's distinct values to a row-mode
// accumulator when results are computed. Other argument types use
// genericState (one map of boxed values per group).
type distinctState struct {
	call *plan.AggCall
	str  bool // STRING argument (else INT-class)
	seed maphash.Seed

	slots []distinctSlot // len is a power of two (or 0)
	used  int

	// Entries in insertion order.
	gids []int32
	ints []int64
	strs []string

	counts []int64 // distinct values per group

	// Entries grouped by group (built once, after the last update, for
	// merging and SUM/AVG results; merges of parallel partitions read the
	// same source state concurrently).
	once    sync.Once
	offsets []int32
	order   []int32
}

// distinctSlot is a hash set slot: the group, the entry index + 1 (0:
// empty) and the value (INT-class) or the value's hash (STRING), so that
// most probes do not touch the entries.
type distinctSlot struct {
	key uint64
	g   int32
	idx int32
}

// distinctArg reports whether distinctState supports argument type t.
func distinctArg(t types.Type) bool {
	switch t.Kind {
	case types.KindBoolean, types.KindInt64, types.KindDate, types.KindTimestamp, types.KindString:
		return true
	case types.KindDecimal:
		return !t.IsWide()
	}
	return false
}

func newDistinctState(call *plan.AggCall) *distinctState {
	return &distinctState{call: call, str: call.Arg.Type().Kind == types.KindString, seed: distinctSeed}
}

// distinctSeed is shared by all states so that hashes stay valid when
// states are merged.
var distinctSeed = maphash.MakeSeed()

func (s *distinctState) grow(g int) { s.counts = growZero(s.counts, g) }

// mix64 is a 64-bit finalizer (MurmurHash3 fmix64).
func mix64(h uint64) uint64 {
	h ^= h >> 33
	h *= 0xff51afd7ed558ccd
	h ^= h >> 33
	h *= 0xc4ceb9fe1a85ec53
	h ^= h >> 33
	return h
}

// slotHash hashes a slot's group and key.
func slotHash(g int32, key uint64) uint64 {
	return mix64(key ^ uint64(uint32(g))*0x9E3779B97F4A7C15)
}

// rehash doubles the slot array.
func (s *distinctState) rehash() {
	n := max(2*len(s.slots), 1024)
	slots := make([]distinctSlot, n)
	mask := uint64(n - 1)
	for _, sl := range s.slots {
		if sl.idx == 0 {
			continue
		}
		i := slotHash(sl.g, sl.key) & mask
		for slots[i].idx != 0 {
			i = (i + 1) & mask
		}
		slots[i] = sl
	}
	s.slots = slots
}

// insert adds an entry for (g, key) unless present (INT-class: key is the
// value; STRING: key is the value's hash and the strings are compared);
// it reports whether the entry is new.
func (s *distinctState) insert(g int32, key uint64, str string) bool {
	if 2*(s.used+1) > len(s.slots) {
		s.rehash()
	}
	mask := uint64(len(s.slots) - 1)
	for i := slotHash(g, key) & mask; ; i = (i + 1) & mask {
		sl := &s.slots[i]
		if sl.idx == 0 {
			*sl = distinctSlot{key: key, g: g, idx: int32(len(s.gids) + 1)}
			s.used++
			s.gids = append(s.gids, g)
			s.counts[g]++
			return true
		}
		if sl.key == key && sl.g == g && (!s.str || s.strs[sl.idx-1] == str) {
			return false
		}
	}
}

func (s *distinctState) addInt(g int32, v int64) {
	if s.insert(g, uint64(v), "") {
		s.ints = append(s.ints, v)
	}
}

func (s *distinctState) addStr(g int32, v string) {
	if s.insert(g, maphash.String(s.seed, v), v) {
		s.strs = append(s.strs, v)
	}
}

func (s *distinctState) update(gids []int32, n int, sel []int32, v *Vec) {
	nulls := v.Nulls
	switch {
	case !s.str:
		vals := v.I
		forActive(n, sel, func(i int) {
			if nulls == nil || !nulls[i] {
				s.addInt(gids[i], vals[i])
			}
		})
	case v.Dict != nil:
		dict, codes := v.Dict, v.Codes
		forActive(n, sel, func(i int) {
			if nulls == nil || !nulls[i] {
				s.addStr(gids[i], dict[codes[i]])
			}
		})
	default:
		vals := v.S
		forActive(n, sel, func(i int) {
			if nulls == nil || !nulls[i] {
				s.addStr(gids[i], vals[i])
			}
		})
	}
}

// byGroup returns the entries of every group in insertion order: the
// entries of group g are order[offsets[g]:offsets[g+1]].
func (s *distinctState) byGroup() (offsets, order []int32) {
	s.once.Do(func() {
		off := make([]int32, len(s.counts)+1)
		for _, g := range s.gids {
			off[g+1]++
		}
		for g := 1; g < len(off); g++ {
			off[g] += off[g-1]
		}
		next := append([]int32(nil), off[:len(s.counts)]...)
		ord := make([]int32, len(s.gids))
		for e, g := range s.gids {
			ord[next[g]] = int32(e)
			next[g]++
		}
		s.offsets, s.order = off, ord
	})
	return s.offsets, s.order
}

func (s *distinctState) merge(g int32, src aggState, sg int32) {
	o := src.(*distinctState)
	off, ord := o.byGroup()
	for _, e := range ord[off[sg]:off[sg+1]] {
		if s.str {
			s.addStr(g, o.strs[e])
		} else {
			s.addInt(g, o.ints[e])
		}
	}
}

func (s *distinctState) result(g int) (types.Value, error) {
	if s.call.Func == plan.AggCount {
		return types.IntValue(s.counts[g]), nil
	}
	call := *s.call
	call.Distinct = false
	acc := newAccumulator(&call)
	off, ord := s.byGroup()
	for _, e := range ord[off[g]:off[g+1]] {
		if s.str {
			_ = acc.add(types.Value{S: s.strs[e]})
		} else {
			_ = acc.add(types.Value{I: s.ints[e]})
		}
	}
	return acc.result()
}
