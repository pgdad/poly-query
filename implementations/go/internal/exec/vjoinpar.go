package exec

import (
	"hash/maphash"

	"polyquery/internal/errs"
	"polyquery/internal/physical"
	"polyquery/internal/types"
)

// Parallel hash join builds. When the build input is a parallel pipeline,
// workers append the morsels they take to partial tables of their own
// (STRING columns encoded with morsel-local dictionaries); the partial
// tables are then concatenated in morsel (table) order — so bucket chains
// keep the insertion order of a serial build — with the dictionaries
// merged, and the result is indexed.

// buildInput is the parallel input of a join build.
type buildInput struct {
	ranges []scanRange
	ops    []BatchOperator
	srcs   []*singleRange
	keys   []*exprSet // per worker
}

// newBuildInput prepares a parallel build input, or returns nil if the
// build side is not a parallel pipeline.
func newBuildInput(ec *Context, buildNode physical.Node, keyExprs func() (*exprSet, error)) (*buildInput, error) {
	ranges, ok := parallelMorsels(ec, buildNode)
	if !ok {
		return nil, nil
	}
	nw := workers(ec, len(ranges))
	ops, srcs, err := batchPipelines(ec, buildNode, nw)
	if err != nil {
		return nil, err
	}
	in := &buildInput{ranges: ranges, ops: ops, srcs: srcs, keys: make([]*exprSet, nw)}
	for w := range in.keys {
		if err := ec.Check(); err != nil {
			return nil, err
		}
		if in.keys[w], err = keyExprs(); err != nil {
			return nil, err
		}
	}
	return in, nil
}

// buildParallel builds the join table from the parallel input.
func (s *joinBuild) buildParallel() (*joinTable, error) {
	in := s.par
	parts := make([]*joinTable, len(in.ranges))
	width := int64(len(s.classes))
	err := runMorsels(s.ec, in.ranges, len(in.ops), func(w, i int) error {
		in.srcs[w].set(in.ranges[i])
		t := &joinTable{classes: s.classes, intKey: s.intKey, cols: make([]Vec, len(s.classes))}
		parts[i] = t
		keys := make([]*Vec, len(s.keyTypes))
		var keyBuf []byte
		for {
			b, err := in.ops[w].NextBatch()
			if b == nil || err != nil {
				return err
			}
			if err := s.ec.Check(); err != nil {
				return err
			}
			if err := in.keys[w].eval(b, b.Sel, keys); err != nil {
				if rowErr := in.keys[w].firstError(b); rowErr != nil {
					return rowErr
				}
				return errs.New(errs.InternalError, "vectorized join key evaluation failed: %v", err)
			}
			bytes := t.appendRows(b, keys, s.keyTypes, &keyBuf)
			if err := s.ec.Mem.Reserve(int64(b.Len())*(40+16*width) + bytes); err != nil {
				return err
			}
		}
	})
	if err != nil {
		return nil, err
	}
	t := concatJoinTables(parts, s.classes, s.intKey, len(in.ops))
	t.index()
	return t, nil
}

// concatJoinTables concatenates partial build tables (not yet indexed) in
// order, copying with up to workers goroutines.
func concatJoinTables(parts []*joinTable, classes []vclass, intKey bool, workers int) *joinTable {
	var used []*joinTable
	for _, p := range parts {
		if p != nil && p.n > 0 {
			used = append(used, p)
		}
	}
	offs := make([]int, len(used)+1)
	for i, p := range used {
		offs[i+1] = offs[i] + p.n
	}
	n := offs[len(used)]
	t := &joinTable{seed: maphash.MakeSeed(), classes: classes, intKey: intKey, n: n, cols: make([]Vec, len(classes))}
	// each runs f(i, off) for every partial table, distributed over the
	// workers.
	nw := max(min(workers, len(used)), 1)
	each := func(f func(i, off int)) {
		parallelDo(nw, func(w int) {
			for i := w; i < len(used); i += nw {
				f(i, offs[i])
			}
		})
	}
	if intKey {
		t.intKeys = make([]int64, n)
		each(func(i, off int) { copy(t.intKeys[off:], used[i].intKeys) })
	} else {
		t.strKeys = make([]string, n)
		each(func(i, off int) { copy(t.strKeys[off:], used[i].strKeys) })
	}
	for k, cls := range classes {
		c := &t.cols[k]
		for _, p := range used {
			if p.cols[k].Nulls != nil {
				c.Nulls = make([]bool, n)
				each(func(i, off int) {
					if nulls := used[i].cols[k].Nulls; nulls != nil {
						copy(c.Nulls[off:], nulls)
					}
				})
				break
			}
		}
		switch cls {
		case vInt:
			c.I = make([]int64, n)
			each(func(i, off int) { copy(c.I[off:], used[i].cols[k].I) })
		case vFloat:
			c.F = make([]float64, n)
			each(func(i, off int) { copy(c.F[off:], used[i].cols[k].F) })
		case vWide:
			c.W = make([]types.Int128, n)
			each(func(i, off int) { copy(c.W[off:], used[i].cols[k].W) })
		default:
			concatStrings(c, k, used, each)
		}
	}
	return t
}

// concatStrings concatenates STRING build column k: dictionary-encoded if
// every partial table encoded it and the merged dictionary stays small,
// plain otherwise.
func concatStrings(c *Vec, k int, used []*joinTable, each func(func(i, off int))) {
	n := 0
	encoded := true
	for _, p := range used {
		n += p.n
		encoded = encoded && p.enc != nil && p.enc[k] != nil
	}
	if encoded {
		merged := &buildDict{index: map[string]uint32{}}
		remaps := make([][]uint32, len(used))
		for i, p := range used {
			dict := p.enc[k].dict
			remaps[i] = make([]uint32, len(dict))
			for code, s := range dict {
				remaps[i][code] = merged.code(s)
			}
		}
		if len(merged.dict) > 0 && len(merged.dict) <= maxBuildDict {
			c.Codes = make([]uint32, n)
			each(func(i, off int) {
				remap := remaps[i]
				for j, code := range used[i].cols[k].Codes {
					if int(code) < len(remap) { // NULL rows of an all-NULL part: code 0
						c.Codes[off+j] = remap[code]
					}
				}
			})
			c.Dict = merged.dict
			return
		}
	}
	c.S = make([]string, n)
	each(func(i, off int) {
		p := used[i]
		if p.enc != nil && p.enc[k] != nil {
			dict := p.enc[k].dict
			for j, code := range p.cols[k].Codes {
				if int(code) < len(dict) {
					c.S[off+j] = dict[code]
				}
			}
			return
		}
		copy(c.S[off:], p.cols[k].S)
	})
}
