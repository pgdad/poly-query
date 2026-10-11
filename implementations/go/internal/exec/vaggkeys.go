package exec

import (
	"math"
	"unsafe"
)

// Multi-column GROUP BY keys. Instead of encoding every row's key values
// into bytes and hashing them, each key column maps its values to dense
// IDs (0 = NULL) — through a per-dictionary code cache, an integer map or,
// for plain strings, a string map behind a cache keyed by string data
// pointer (strings gathered from the same dictionary entry or build row
// share their bytes) — and the IDs of a row are combined column by column
// through integer maps: level k maps (combined ID of keys 0..k-1, ID of
// key k) to a combined ID; the last level yields the group.

// keyIDs assigns dense IDs to the values of one key column.
type keyIDs struct {
	cls  vclass
	ints i64Map           // vInt, vFloat (bits, -0 folded)
	strs map[string]int32 // vStr
	n    int32            // IDs assigned (IDs start at 1)

	dict    []string // dictionary of the code cache
	dictIDs []int32  // per code: ID, 0 = not cached
	ptrs    [256]ptrEntry

	out []int32 // IDs of the current batch
}

type ptrEntry struct {
	p  *byte
	n  int
	id int32
}

func newKeyIDs(cls vclass) *keyIDs {
	k := &keyIDs{cls: cls}
	if cls == vStr {
		k.strs = map[string]int32{}
	}
	return k
}

func (k *keyIDs) intID(x int64) int32 {
	if id, ok := k.ints.get(x); ok {
		return id
	}
	k.n++
	k.ints.put(x, k.n)
	return k.n
}

func (k *keyIDs) strID(s string) int32 {
	id, ok := k.strs[s]
	if !ok {
		k.n++
		id = k.n
		k.strs[s] = id
	}
	return id
}

// cachedStrID looks a plain string up through the data pointer cache.
func (k *keyIDs) cachedStrID(s string) int32 {
	p := unsafe.StringData(s)
	e := &k.ptrs[(uintptr(unsafe.Pointer(p))>>3^uintptr(len(s)))&uintptr(len(k.ptrs)-1)]
	if e.p == p && e.n == len(s) && e.id != 0 {
		return e.id
	}
	id := k.strID(s)
	*e = ptrEntry{p: p, n: len(s), id: id}
	return id
}

// ids computes the IDs of the active rows of v (in k.out, indexed by row).
func (k *keyIDs) ids(v *Vec, n int, sel []int32) []int32 {
	k.out = grow(k.out, n)
	out, nulls := k.out, v.Nulls
	switch {
	case k.cls == vInt:
		vals := v.I
		forActive(n, sel, func(i int) { out[i] = k.intID(vals[i]) })
	case k.cls == vFloat:
		vals := v.F
		forActive(n, sel, func(i int) {
			f := vals[i]
			if f == 0 {
				f = 0 // -0 equals 0
			}
			out[i] = k.intID(int64(math.Float64bits(f)))
		})
	case v.Dict != nil:
		if !sameDict(k.dict, v.Dict) {
			k.dict = v.Dict
			k.dictIDs = grow(k.dictIDs, len(v.Dict))
			clear(k.dictIDs)
		}
		codes, cache := v.Codes, k.dictIDs
		forActive(n, sel, func(i int) {
			c := codes[i]
			id := cache[c]
			if id == 0 {
				id = k.strID(k.dict[c])
				cache[c] = id
			}
			out[i] = id
		})
	default:
		vals := v.S
		forActive(n, sel, func(i int) { out[i] = k.cachedStrID(vals[i]) })
	}
	if nulls != nil {
		forActive(n, sel, func(i int) {
			if nulls[i] {
				out[i] = 0
			}
		})
	}
	return out
}

// multiKeys resolves multi-column keys (no wide DECIMAL key).
type multiKeys struct {
	cols   []*keyIDs
	levels []i64Map // levels[k-1]: (combined ID of keys < k, ID of key k) → ID
	counts []int32  // IDs assigned per intermediate level
}

func newMultiKeys(classes []vclass) *multiKeys {
	m := &multiKeys{levels: make([]i64Map, len(classes)-1), counts: make([]int32, len(classes)-1)}
	for _, c := range classes {
		m.cols = append(m.cols, newKeyIDs(c))
	}
	return m
}

func multiKeysApply(classes []vclass) bool {
	if len(classes) < 2 {
		return false
	}
	for _, c := range classes {
		if c == vWide {
			return false
		}
	}
	return true
}

// resolveMulti computes the group of every active row with multi-column
// keys (creating groups).
func (t *aggTable) resolveMulti(keys []*Vec, n int, sel []int32, pos int64) error {
	m := t.multi
	ids := make([][]int32, len(keys))
	for k, v := range keys {
		ids[k] = m.cols[k].ids(v, n, sel)
	}
	last := len(keys) - 1
	gids := t.gids
	one := func(i int) error {
		cur := ids[0][i]
		for k := 1; k < last; k++ {
			key := int64(cur)<<32 | int64(ids[k][i])
			next, ok := m.levels[k-1].get(key)
			if !ok {
				m.counts[k-1]++
				next = m.counts[k-1]
				m.levels[k-1].put(key, next)
			}
			cur = next
		}
		key := int64(cur)<<32 | int64(ids[last][i])
		g, ok := m.levels[last-1].get(key)
		if !ok {
			var err error
			if g, err = t.newGroup(t.keyRow(keys, i), pos+int64(i)); err != nil {
				return err
			}
			m.levels[last-1].put(key, g)
		}
		gids[i] = g
		return nil
	}
	if sel == nil {
		for i := 0; i < n; i++ {
			if err := one(i); err != nil {
				return err
			}
		}
		return nil
	}
	for _, i := range sel {
		if err := one(int(i)); err != nil {
			return err
		}
	}
	return nil
}
