package exec

import (
	"hash/maphash"
	"math"
	"sync"

	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Partitioned parallel aggregation. A worker pre-aggregates its morsels
// into a private table (aggTable) as long as that reduces the data; once
// its table holds about as many groups as rows (high-cardinality keys),
// merging the partial tables would insert most rows twice. The worker then
// scatters the evaluated keys and arguments of its rows, with their input
// positions, into one buffer per partition (by key hash, see rowPartHash).
// Finally every partition is aggregated by its own goroutine: the groups
// of the partial tables in that partition are merged, and its buffered
// rows are folded in batch by batch. Groups keep their first position, so
// the output order is the same as with any other strategy.

// scatterMinRows and scatterGroupRatio decide when a worker switches to
// scattering: after at least scatterMinRows rows, when its table has more
// than one group per scatterGroupRatio rows.
const (
	scatterMinRows    = 1 << 15
	scatterGroupRatio = 3
)

// aggChunk holds up to BatchSize buffered rows of a partition: key and
// argument columns (arguments only for calls with one) and input
// positions. Columns are allocated with their final capacity, so appending
// never copies.
type aggChunk struct {
	keys []Vec
	args []Vec
	pos  []int64
}

func newAggChunk(keyClasses, argClasses []vclass, hasArg []bool) *aggChunk {
	c := &aggChunk{keys: make([]Vec, len(keyClasses)), args: make([]Vec, len(argClasses)),
		pos: make([]int64, 0, BatchSize)}
	for k, cls := range keyClasses {
		c.keys[k] = newChunkVec(cls)
	}
	for a, cls := range argClasses {
		if hasArg[a] {
			c.args[a] = newChunkVec(cls)
		}
	}
	return c
}

func newChunkVec(c vclass) Vec {
	v := Vec{Nulls: make([]bool, 0, BatchSize)}
	switch c {
	case vInt:
		v.I = make([]int64, 0, BatchSize)
	case vFloat:
		v.F = make([]float64, 0, BatchSize)
	case vWide:
		v.W = make([]types.Int128, 0, BatchSize)
	default:
		v.S = make([]string, 0, BatchSize)
	}
	return v
}

// appendValue appends row i of src (class c) to dst, with its NULL flag.
func appendValue(dst *Vec, src *Vec, i int, c vclass) {
	null := src.Nulls != nil && src.Nulls[i]
	dst.Nulls = append(dst.Nulls, null)
	switch c {
	case vInt:
		dst.I = append(dst.I, src.I[i])
	case vFloat:
		dst.F = append(dst.F, src.F[i])
	case vWide:
		dst.W = append(dst.W, src.W[i])
	default:
		var s string
		if !null {
			if src.Dict != nil {
				s = src.Dict[src.Codes[i]]
			} else {
				s = src.S[i]
			}
		}
		dst.S = append(dst.S, s)
	}
}

// aggScatter is a worker's set of partition buffers.
type aggScatter struct {
	ec         *Context
	seed       maphash.Seed
	keyClasses []vclass
	keyTypes   []types.Type
	argClasses []vclass // per call; COUNT(*) has none
	hasArg     []bool
	parts      [][]*aggChunk // per partition; the last chunk is being filled
	key        []byte
	unreserved int64
}

func newAggScatter(ec *Context, seed maphash.Seed, parts int, keyTypes []types.Type, calls []*plan.AggCall) *aggScatter {
	s := &aggScatter{ec: ec, seed: seed, keyTypes: keyTypes, parts: make([][]*aggChunk, parts)}
	for _, t := range keyTypes {
		s.keyClasses = append(s.keyClasses, classOf(t))
	}
	for _, c := range calls {
		s.hasArg = append(s.hasArg, c.Arg != nil)
		if c.Arg != nil {
			s.argClasses = append(s.argClasses, classOf(c.Arg.Type()))
		} else {
			s.argClasses = append(s.argClasses, vInt)
		}
	}
	return s
}

// rowPartHash is groupPartHash for the keys of row i.
func (s *aggScatter) rowPartHash(keys []*Vec, i int) uint64 {
	if len(keys) == 1 && !keys[0].isNull(i) {
		v := keys[0]
		switch s.keyClasses[0] {
		case vInt:
			return intPartHash(v.I[i])
		case vStr:
			if v.Dict != nil {
				return strPartHash(strKeyHash(v.Dict[v.Codes[i]]))
			}
			return strPartHash(strKeyHash(v.S[i]))
		}
	}
	s.key = s.key[:0]
	for k, v := range keys {
		s.key = appendKey(s.key, v.value(i, s.keyClasses[k]), s.keyTypes[k])
	}
	return maphash.Bytes(s.seed, s.key)
}

// add buffers the active rows of an evaluated batch at input position pos.
func (s *aggScatter) add(keys, args []*Vec, n int, sel []int32, pos int64) error {
	parts := uint64(len(s.parts))
	var bytes int64
	forActive(n, sel, func(i int) {
		chunks := &s.parts[s.rowPartHash(keys, i)%parts]
		if len(*chunks) == 0 || len((*chunks)[len(*chunks)-1].pos) == BatchSize {
			*chunks = append(*chunks, newAggChunk(s.keyClasses, s.argClasses, s.hasArg))
			bytes += int64(BatchSize * 9 * (len(keys) + len(args) + 1))
		}
		p := (*chunks)[len(*chunks)-1]
		for k, v := range keys {
			appendValue(&p.keys[k], v, i, s.keyClasses[k])
		}
		for a, v := range args {
			if s.hasArg[a] {
				appendValue(&p.args[a], v, i, s.argClasses[a])
			}
		}
		p.pos = append(p.pos, pos+int64(i))
	})
	s.unreserved += bytes
	if s.unreserved >= reserveChunk {
		n := s.unreserved
		s.unreserved = 0
		return s.ec.Mem.Reserve(n)
	}
	return nil
}

// foldInto folds the rows of partition p into t, chunk by chunk.
func (s *aggScatter) foldInto(t *aggTable, p int) error {
	keys := make([]*Vec, len(s.keyClasses))
	args := make([]*Vec, len(s.argClasses))
	defer func() { t.rowPos = nil }()
	for _, c := range s.parts[p] {
		for k := range c.keys {
			keys[k] = &c.keys[k]
		}
		for a := range c.args {
			if s.hasArg[a] {
				args[a] = &c.args[a]
			}
		}
		t.rowPos = c.pos
		if err := t.update(keys, args, len(c.pos), nil, 0); err != nil {
			return err
		}
	}
	return s.ec.Check()
}

// mergePartitioned computes the result rows of a parallel aggregation in
// which some workers scattered rows (scatters[w] non-nil): partition p
// of every partial table and every scatter is aggregated by goroutine p.
func mergePartitioned(ec *Context, seed maphash.Seed, tables []*aggTable, scatters []*aggScatter, keyTypes []types.Type, calls []*plan.AggCall) ([]types.Row, error) {
	parts := len(tables)
	partGroups := make([][][]int32, len(tables)) // table → partition → groups
	var wg sync.WaitGroup
	for i, t := range tables {
		wg.Add(1)
		go func() {
			defer wg.Done()
			partGroups[i] = t.partitionGroups(seed, parts)
		}()
	}
	wg.Wait()
	type partResult struct {
		rows   []types.Row
		first  []int64
		errPos int64
		err    error
	}
	results := make([]partResult, parts)
	for p := 0; p < parts; p++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := &results[p]
			final := newAggTable(ec, keyTypes, calls)
			for i, t := range tables {
				for _, g := range partGroups[i][p] {
					if err := final.mergeGroup(t, g); err != nil {
						*r = partResult{errPos: math.MinInt64, err: err}
						return
					}
				}
			}
			for _, s := range scatters {
				if s == nil {
					continue
				}
				if err := s.foldInto(final, p); err != nil {
					*r = partResult{errPos: math.MinInt64, err: err}
					return
				}
			}
			r.rows, r.first, r.errPos, r.err = final.results()
			if r.err == nil {
				r.rows = orderByFirst(r.rows, r.first)
			}
		}()
	}
	wg.Wait()
	var err error
	errPos := int64(math.MaxInt64)
	rows := make([][]types.Row, parts)
	first := make([][]int64, parts)
	for p, r := range results {
		if r.err != nil && r.errPos < errPos {
			errPos, err = r.errPos, r.err
		}
		rows[p], first[p] = r.rows, r.first
	}
	if err != nil {
		return nil, err
	}
	return mergeByFirst(rows, first), nil
}
