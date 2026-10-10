package exec

import (
	"hash/maphash"
	"math/bits"

	"polyquery/internal/errs"
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Vectorized hash join. The build input is materialized column-wise into a
// joinTable: a bucket array (heads) plus one "next" link and one key per
// build row — three flat arrays instead of a map of slices, so probing
// touches few cache lines. Chains list build rows in insertion order.
// Probe batches are joined into output batches of pairs (probe row, build
// row) whose columns are gathered from both sides.

// joinTable is the materialized, hashed build side of a hash join.
type joinTable struct {
	classes []vclass
	cols    []Vec // build rows, column-wise (Nulls allocated on first NULL)
	n       int
	intKeys []int64  // single int-class key with identical representation on both sides
	strKeys []string // canonical encoded keys otherwise
	intKey  bool
	heads   []int32
	next    []int32
	shift   uint
	seed    maphash.Seed
}

func hashInt(k int64, shift uint) uint64 {
	return (uint64(k) * 0x9E3779B97F4A7C15) >> shift
}

func (t *joinTable) bucketOfString(s []byte) uint64 {
	return maphash.Bytes(t.seed, s) >> t.shift
}

// appendRows appends the active rows of b with their keys to the table.
func (t *joinTable) appendRows(b *Batch, keys []*Vec, keyTypes []types.Type, keyBuf *[]byte) (int64, error) {
	var bytes int64
	keyClasses := make([]vclass, len(keys))
	for k, kt := range keyTypes {
		keyClasses[k] = classOf(kt)
	}
	for k, v := range b.Cols {
		if t.classes[k] == vStr {
			v.strs(b.N)
		}
	}
	forActive(b.N, b.Sel, func(i int) {
		for _, kv := range keys {
			if kv.isNull(i) {
				return // NULL keys never match
			}
		}
		if t.intKey {
			t.intKeys = append(t.intKeys, keys[0].I[i])
		} else {
			kb := (*keyBuf)[:0]
			for k, kv := range keys {
				kb = appendKey(kb, kv.value(i, keyClasses[k]), keyTypes[k])
			}
			*keyBuf = kb
			t.strKeys = append(t.strKeys, string(kb))
			bytes += int64(len(kb))
		}
		for k, v := range b.Cols {
			c := &t.cols[k]
			isNull := v.isNull(i)
			if isNull && c.Nulls == nil {
				c.Nulls = make([]bool, t.n, max(t.n, 16))
			}
			if c.Nulls != nil {
				c.Nulls = append(c.Nulls, isNull)
			}
			switch t.classes[k] {
			case vInt:
				c.I = append(c.I, v.I[i])
			case vFloat:
				c.F = append(c.F, v.F[i])
			default:
				c.S = append(c.S, v.S[i])
				bytes += int64(len(v.S[i]))
			}
		}
		t.n++
	})
	return bytes, nil
}

// index builds the bucket chains.
func (t *joinTable) index() {
	size := 16
	for size < 2*t.n {
		size <<= 1
	}
	t.shift = uint(64 - bits.TrailingZeros(uint(size)))
	t.heads = make([]int32, size)
	for i := range t.heads {
		t.heads[i] = -1
	}
	t.next = make([]int32, t.n)
	for i := t.n - 1; i >= 0; i-- {
		var h uint64
		if t.intKey {
			h = hashInt(t.intKeys[i], t.shift)
		} else {
			h = maphash.String(t.seed, t.strKeys[i]) >> t.shift
		}
		t.next[i] = t.heads[h]
		t.heads[h] = int32(i)
	}
}

// vhashJoinOp is the vectorized hash join (INNER and LEFT).
type vhashJoinOp struct {
	ec        *Context
	node      *physical.HashJoin
	kind      plan.JoinKind
	buildLeft bool
	build     BatchOperator
	probe     BatchOperator
	buildKeys *exprSet
	probeKeys *exprSet
	keyTypesB []types.Type
	keyTypesP []types.Type
	residual  *exprSet // over the output layout; nil if none
	table     *joinTable
	built     bool

	// probe state
	pb         *Batch
	pbuf       Batch
	pkeys      []*Vec
	active     int  // number of active probe rows to process
	pos        int  // index (into the active rows) of the current probe row
	chain      int32
	inChain    bool
	matchedRow bool
	matched    []bool // per probe row (LEFT with residual)
	unmatched  bool   // emitting unmatched rows of the current batch
	batchErr   error  // error after the processed probe rows
	keyBuf     []byte

	pairP, pairB []int32
	outCols      []vclass
	bufs         []vecBuf
	codes        [][]uint32
	out          Batch
	sel          []int32
	emitted      int64
	pending      error
}

func buildVHashJoin(ec *Context, x *physical.HashJoin) (BatchOperator, error) {
	left, err := BuildBatch(ec, x.Left)
	if err != nil {
		return nil, err
	}
	right, err := BuildBatch(ec, x.Right)
	if err != nil {
		return nil, err
	}
	op := &vhashJoinOp{ec: ec, node: x, kind: x.Kind, buildLeft: x.BuildLeft}
	buildNode, probeNode := x.Right, x.Left
	buildKeys, probeKeys := x.RightKeys, x.LeftKeys
	op.build, op.probe = right, left
	if x.BuildLeft {
		buildNode, probeNode = x.Left, x.Right
		buildKeys, probeKeys = x.LeftKeys, x.RightKeys
		op.build, op.probe = left, right
	}
	if op.buildKeys, err = newExprSet(ec, buildNode.Schema(), buildKeys); err != nil {
		return nil, err
	}
	if op.probeKeys, err = newExprSet(ec, probeNode.Schema(), probeKeys); err != nil {
		return nil, err
	}
	op.keyTypesB, op.keyTypesP = exprTypes(buildKeys), exprTypes(probeKeys)
	if x.Residual != nil {
		if op.residual, err = newExprSet(ec, x.Schema(), []plan.Expr{x.Residual}); err != nil {
			return nil, err
		}
	}
	t := &joinTable{seed: maphash.MakeSeed()}
	for _, c := range buildNode.Schema() {
		t.classes = append(t.classes, classOf(c.Type))
	}
	t.cols = make([]Vec, len(t.classes))
	kb, kp := op.keyTypesB[0], op.keyTypesP[0]
	t.intKey = len(buildKeys) == 1 && classOf(kb) == vInt && kb.Kind == kp.Kind && kb.Scale == kp.Scale
	op.table = t
	for _, c := range x.Schema() {
		op.outCols = append(op.outCols, classOf(c.Type))
	}
	op.bufs = make([]vecBuf, len(op.outCols))
	op.codes = make([][]uint32, len(op.outCols))
	op.out.Cols = make([]*Vec, len(op.outCols))
	op.pkeys = make([]*Vec, len(probeKeys))
	return op, nil
}

func (j *vhashJoinOp) buildTable() error {
	keys := make([]*Vec, len(j.keyTypesB))
	for {
		b, err := j.build.NextBatch()
		if err != nil {
			return err
		}
		if b == nil {
			break
		}
		if err := j.ec.Check(); err != nil {
			return err
		}
		if err := j.buildKeys.eval(b, b.Sel, keys); err != nil {
			if rowErr := j.buildKeys.firstError(b); rowErr != nil {
				return rowErr
			}
			return errs.New(errs.InternalError, "vectorized join key evaluation failed: %v", err)
		}
		bytes, err := j.table.appendRows(b, keys, j.keyTypesB, &j.keyBuf)
		if err != nil {
			return err
		}
		width := int64(len(j.table.classes))
		if err := j.ec.Mem.Reserve(int64(b.Len())*(40+16*width) + bytes); err != nil {
			return err
		}
	}
	j.table.index()
	return nil
}

// nextProbeBatch fetches and prepares the next probe batch; false at end.
func (j *vhashJoinOp) nextProbeBatch() (bool, error) {
	b, err := j.probe.NextBatch()
	if b == nil || err != nil {
		return false, err
	}
	if err := j.ec.Check(); err != nil {
		return false, err
	}
	j.pbuf = *b // private copy: the selection may be replaced below
	b = &j.pbuf
	j.pb, j.pos, j.inChain, j.unmatched = b, 0, false, false
	j.active = b.Len()
	if err := j.probeKeys.eval(b, b.Sel, j.pkeys); err != nil {
		// Process the rows before the first failing one, then fail.
		j.active, j.batchErr = j.firstKeyError(b)
		if j.active > 0 {
			if err := j.probeKeys.eval(b, b.Sel[:j.active:j.active], j.pkeys); err != nil {
				return false, j.batchErr
			}
		}
	}
	if j.kind == plan.JoinLeft && j.residual != nil {
		j.matched = grow(j.matched, b.N)
		clear(j.matched)
	}
	if b.Sel == nil && j.active < b.N {
		// Address active rows through a selection vector.
		sel := make([]int32, j.active)
		for i := range sel {
			sel[i] = int32(i)
		}
		b.Sel = sel
	}
	return true, nil
}

// firstKeyError evaluates the probe keys row by row and returns the number
// of rows before the first error and that error.
func (j *vhashJoinOp) firstKeyError(b *Batch) (int, error) {
	dst := make(types.Row, len(j.pkeys))
	n := b.Len()
	if b.Sel == nil {
		sel := make([]int32, n)
		for i := range sel {
			sel[i] = int32(i)
		}
		b.Sel = sel
	}
	for k := 0; k < n; k++ {
		if err := j.probeKeys.evalRow(b, int(b.Sel[k]), dst); err != nil {
			return k, err
		}
	}
	return n, nil
}

func (j *vhashJoinOp) rowAt(k int) int {
	if j.pb.Sel != nil {
		return int(j.pb.Sel[k])
	}
	return k
}

// fillPairs collects up to BatchSize (probe row, build row) pairs of the
// current probe batch; build row -1 denotes a NULL-extended row.
func (j *vhashJoinOp) fillPairs() {
	t := j.table
	pp, pbuild := j.pairP[:0], j.pairB[:0]
	leftNoResidual := j.kind == plan.JoinLeft && j.residual == nil
	for j.pos < j.active && len(pp) < BatchSize {
		i := j.rowAt(j.pos)
		if !j.inChain {
			j.inChain, j.matchedRow, j.chain = true, false, -1
			hasNull := false
			for _, kv := range j.pkeys {
				hasNull = hasNull || kv.isNull(i)
			}
			if !hasNull {
				if t.intKey {
					j.chain = t.heads[hashInt(j.pkeys[0].I[i], t.shift)]
				} else {
					j.keyBuf = j.keyBuf[:0]
					for k, kv := range j.pkeys {
						j.keyBuf = appendKey(j.keyBuf, kv.value(i, classOf(j.keyTypesP[k])), j.keyTypesP[k])
					}
					j.chain = t.heads[t.bucketOfString(j.keyBuf)]
				}
			}
		}
		if t.intKey {
			k := j.pkeys[0].I[i]
			for j.chain >= 0 && len(pp) < BatchSize {
				c := j.chain
				j.chain = t.next[c]
				if t.intKeys[c] == k {
					pp, pbuild = append(pp, int32(i)), append(pbuild, c)
					j.matchedRow = true
				}
			}
		} else {
			for j.chain >= 0 && len(pp) < BatchSize {
				c := j.chain
				j.chain = t.next[c]
				if t.strKeys[c] == string(j.keyBuf) {
					pp, pbuild = append(pp, int32(i)), append(pbuild, c)
					j.matchedRow = true
				}
			}
		}
		if j.chain >= 0 {
			break // output full; continue this chain next time
		}
		if leftNoResidual && !j.matchedRow {
			if len(pp) >= BatchSize {
				break
			}
			pp, pbuild = append(pp, int32(i)), append(pbuild, -1)
		}
		j.inChain = false
		j.pos++
	}
	j.pairP, j.pairB = pp, pbuild
}

// gather builds the output batch of the current pairs: left columns, then
// right columns.
func (j *vhashJoinOp) gather() *Batch {
	n := len(j.pairP)
	leftW := len(j.pb.Cols)
	if j.buildLeft {
		leftW = len(j.table.classes)
	}
	for k := range j.outCols {
		probeCol := k < leftW != j.buildLeft
		src := k
		if k >= leftW {
			src = k - leftW
		}
		if probeCol {
			j.out.Cols[k] = j.gatherProbe(k, j.pb.Cols[src], n)
		} else {
			j.out.Cols[k] = j.gatherBuild(k, &j.table.cols[src], n)
		}
	}
	j.out.N, j.out.Sel = n, nil
	return &j.out
}

func (j *vhashJoinOp) gatherProbe(k int, v *Vec, n int) *Vec {
	cls := j.outCols[k]
	buf := &j.bufs[k]
	out := buf.reset(n, cls)
	idx := j.pairP[:n]
	switch {
	case cls == vInt:
		for o, i := range idx {
			out.I[o] = v.I[i]
		}
	case cls == vFloat:
		for o, i := range idx {
			out.F[o] = v.F[i]
		}
	case v.Dict != nil:
		codes := grow(j.codes[k], n)
		j.codes[k] = codes
		for o, i := range idx {
			codes[o] = v.Codes[i]
		}
		out.S = out.S[:0]
		out.Dict, out.Codes = v.Dict, codes
	default:
		for o, i := range idx {
			out.S[o] = v.S[i]
		}
	}
	if v.Nulls != nil {
		nulls := buf.withNulls(n)
		for o, i := range idx {
			nulls[o] = v.Nulls[i]
		}
	}
	return out
}

func (j *vhashJoinOp) gatherBuild(k int, v *Vec, n int) *Vec {
	cls := j.outCols[k]
	buf := &j.bufs[k]
	out := buf.reset(n, cls)
	idx := j.pairB[:n]
	var nulls []bool
	if v.Nulls != nil || j.kind == plan.JoinLeft {
		nulls = buf.withNulls(n)
	}
	for o, b := range idx {
		if b < 0 {
			nulls[o] = true
			continue
		}
		if v.Nulls != nil && v.Nulls[b] {
			nulls[o] = true
			continue
		}
		switch cls {
		case vInt:
			out.I[o] = v.I[b]
		case vFloat:
			out.F[o] = v.F[b]
		default:
			out.S[o] = v.S[b]
		}
	}
	return out
}

// applyResidual filters the output batch by the residual condition (and
// records matches for LEFT joins). A failure is evaluated row by row: the
// rows before the first error are kept and the error is reported next.
func (j *vhashJoinOp) applyResidual(b *Batch) {
	res := make([]*Vec, 1)
	sel := j.sel[:0]
	if err := j.residual.eval(b, nil, res); err != nil {
		v := make(types.Row, 1)
		for i := 0; i < b.N; i++ {
			if err := j.residual.evalRow(b, i, v); err != nil {
				j.pending = err
				break
			}
			if v[0].IsTrue() {
				sel = append(sel, int32(i))
			}
		}
	} else {
		r := res[0]
		for i := 0; i < b.N; i++ {
			if r.I[i] != 0 && (r.Nulls == nil || !r.Nulls[i]) {
				sel = append(sel, int32(i))
			}
		}
	}
	j.sel = sel
	if j.matched != nil && j.kind == plan.JoinLeft {
		for _, i := range sel {
			j.matched[j.pairP[i]] = true
		}
	}
	b.Sel = sel
}

// unmatchedPairs emits the probe rows of the current batch without a
// match (LEFT joins with a residual condition).
func (j *vhashJoinOp) unmatchedPairs() {
	pp, pbuild := j.pairP[:0], j.pairB[:0]
	for k := 0; k < j.active; k++ {
		i := j.rowAt(k)
		if !j.matched[i] {
			pp, pbuild = append(pp, int32(i)), append(pbuild, -1)
		}
	}
	j.pairP, j.pairB = pp, pbuild
}

func (j *vhashJoinOp) NextBatch() (*Batch, error) {
	if j.pending != nil {
		err := j.pending
		j.pending = nil
		return nil, err
	}
	if !j.built {
		j.built = true
		if err := j.buildTable(); err != nil {
			return nil, err
		}
	}
	for {
		if j.pb == nil {
			ok, err := j.nextProbeBatch()
			if !ok || err != nil {
				return nil, err
			}
		}
		if j.pos >= j.active {
			// Probe batch exhausted.
			if j.kind == plan.JoinLeft && j.residual != nil && !j.unmatched {
				j.unmatched = true
				j.unmatchedPairs()
				if len(j.pairP) > 0 {
					return j.emit(j.gather())
				}
			}
			j.pb = nil
			if j.batchErr != nil {
				err := j.batchErr
				j.batchErr = nil
				return nil, err
			}
			continue
		}
		j.fillPairs()
		if len(j.pairP) == 0 {
			continue
		}
		b := j.gather()
		if j.residual != nil {
			j.applyResidual(b)
			if len(b.Sel) == 0 {
				if j.pending != nil {
					err := j.pending
					j.pending = nil
					return nil, err
				}
				continue
			}
		}
		return j.emit(b)
	}
}

// emit enforces --max-join-rows: at most the remaining allowance of rows
// is returned, the error follows on the next call.
func (j *vhashJoinOp) emit(b *Batch) (*Batch, error) {
	n := int64(b.Len())
	if limit := j.ec.MaxJoinRows; limit > 0 && j.emitted+n > limit {
		allowed := limit - j.emitted
		j.pending = errs.New(errs.ResourceLimit, "join produced more than %d rows", limit)
		if allowed <= 0 {
			err := j.pending
			j.pending = nil
			return nil, err
		}
		if b.Sel == nil {
			sel := make([]int32, allowed)
			for i := range sel {
				sel[i] = int32(i)
			}
			b.Sel = sel
		} else {
			b.Sel = b.Sel[:allowed]
		}
		n = allowed
	}
	j.emitted += n
	return b, nil
}
