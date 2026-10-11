package exec

import (
	"math"

	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// distinctState computes COUNT/SUM/AVG(DISTINCT x) over int-class, FLOAT64
// and STRING arguments: a set of (group, value) pairs filters the rows of a
// batch down to the first occurrence of each value per group, which are
// fed to the state of the plain aggregate. Each group also lists its
// distinct values in insertion order, so merging partial tables feeds the
// values in a deterministic order (FLOAT64 sums do not depend on hashing).
type distinctState struct {
	cls   vclass
	inner aggState

	nums pairSet                  // vInt, vFloat (bits of the value, -0 folded)
	strs map[distinctStr]struct{} // vStr

	// Per group: singly linked list of its distinct values (entry index +
	// 1; 0 = none).
	head, tail []int32
	next       []int32
	ints       []int64  // entry values (vInt, vFloat bits)
	strVals    []string // entry values (vStr)

	sel []int32 // rows of the current batch that are new for their group
	one Vec     // single-value vector used by merge
	g1  [1]int32
}

type distinctStr struct {
	g int32
	s string
}

// newDistinctState returns the state of a DISTINCT aggregate, or nil when
// the argument class or the aggregate has no specialized state.
func newDistinctState(call *plan.AggCall, cls vclass) aggState {
	if cls == vWide {
		return nil
	}
	plain := *call
	plain.Distinct = false
	inner := newAggState(&plain)
	if _, ok := inner.(*genericState); ok {
		return nil
	}
	s := &distinctState{cls: cls, inner: inner}
	if cls == vStr {
		s.strs = map[distinctStr]struct{}{}
	}
	return s
}

func (s *distinctState) grow(g int) {
	s.head = growZero(s.head, g)
	s.tail = growZero(s.tail, g)
	s.inner.grow(g)
}

// link appends a new entry (already stored at the end of the value slice)
// to the list of group g.
func (s *distinctState) link(g int32) {
	e := int32(len(s.next)) + 1
	s.next = append(s.next, 0)
	if s.tail[g] == 0 {
		s.head[g] = e
	} else {
		s.next[s.tail[g]-1] = e
	}
	s.tail[g] = e
}

// numKey is the set key of row i of an int-class or FLOAT64 vector.
func (s *distinctState) numKey(v *Vec, i int) int64 {
	if s.cls == vFloat {
		f := v.F[i]
		if f == 0 {
			f = 0 // fold -0.0 into 0.0
		}
		return int64(math.Float64bits(f))
	}
	return v.I[i]
}

func (s *distinctState) addNum(g int32, k int64) bool {
	if !s.nums.add(g, k) {
		return false
	}
	s.ints = append(s.ints, k)
	s.link(g)
	return true
}

func (s *distinctState) addStr(g int32, str string) bool {
	key := distinctStr{g, str}
	if _, ok := s.strs[key]; ok {
		return false
	}
	s.strs[key] = struct{}{}
	s.strVals = append(s.strVals, str)
	s.link(g)
	return true
}

func (s *distinctState) update(gids []int32, n int, sel []int32, v *Vec) {
	s.sel = s.sel[:0]
	var strs []string
	if s.cls == vStr {
		strs = v.strs(n)
	}
	nulls := v.Nulls
	forActive(n, sel, func(i int) {
		if nulls != nil && nulls[i] {
			return
		}
		var isNew bool
		if s.cls == vStr {
			isNew = s.addStr(gids[i], strs[i])
		} else {
			isNew = s.addNum(gids[i], s.numKey(v, i))
		}
		if isNew {
			s.sel = append(s.sel, int32(i))
		}
	})
	if len(s.sel) > 0 {
		s.inner.update(gids, n, s.sel, v)
	}
}

func (s *distinctState) merge(g int32, src aggState, sg int32) {
	o := src.(*distinctState)
	s.g1[0] = g
	for e := o.head[sg]; e != 0; e = o.next[e-1] {
		switch s.cls {
		case vStr:
			str := o.strVals[e-1]
			if !s.addStr(g, str) {
				continue
			}
			s.one.S = append(s.one.S[:0], str)
		case vFloat:
			k := o.ints[e-1]
			if !s.addNum(g, k) {
				continue
			}
			s.one.F = append(s.one.F[:0], math.Float64frombits(uint64(k)))
		default:
			k := o.ints[e-1]
			if !s.addNum(g, k) {
				continue
			}
			s.one.I = append(s.one.I[:0], k)
		}
		s.inner.update(s.g1[:], 1, nil, &s.one)
	}
}

func (s *distinctState) result(g int) (types.Value, error) { return s.inner.result(g) }
