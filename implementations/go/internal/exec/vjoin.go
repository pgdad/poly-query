package exec

import (
	"hash/maphash"
	"math/bits"
	"sync"
	"sync/atomic"

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
	rows    []int32 // scratch: stored rows of the current batch
	// enc dictionary-encodes STRING build columns while their number of
	// distinct values stays small (nil entries: plain columns); probes
	// then emit dictionary-encoded vectors.
	enc []*buildDict
}

// maxBuildDict is the number of distinct values from which a STRING build
// column is stored plainly.
const maxBuildDict = 1 << 14

// buildDict encodes the values of one STRING build column.
type buildDict struct {
	dict   []string
	index  map[string]uint32
	inDict []string // dictionary of the last dictionary-encoded input …
	inMap  []int32  // … and its codes mapped to ours (+1; 0 = unmapped)
}

func (d *buildDict) code(s string) uint32 {
	c, ok := d.index[s]
	if !ok {
		c = uint32(len(d.dict))
		d.dict = append(d.dict, s)
		d.index[s] = c
	}
	return c
}

// codeOf encodes row i of v (not NULL).
func (d *buildDict) codeOf(v *Vec, i int) uint32 {
	if v.Dict == nil {
		return d.code(v.S[i])
	}
	if !sameDict(d.inDict, v.Dict) {
		d.inDict = v.Dict
		d.inMap = grow(d.inMap, len(v.Dict))
		clear(d.inMap)
	}
	in := v.Codes[i]
	if m := d.inMap[in]; m != 0 {
		return uint32(m - 1)
	}
	c := d.code(v.Dict[in])
	d.inMap[in] = int32(c) + 1
	return c
}

// decode turns dictionary-encoded build column k into a plain one.
func (t *joinTable) decode(k int) {
	c, d := &t.cols[k], t.enc[k]
	c.S = make([]string, len(c.Codes), max(cap(c.Codes), 16))
	for i, code := range c.Codes {
		c.S[i] = d.dict[code]
	}
	c.Codes, t.enc[k] = nil, nil
}

func hashInt(k int64, shift uint) uint64 {
	return (uint64(k) * 0x9E3779B97F4A7C15) >> shift
}

func (t *joinTable) bucketOfString(s []byte) uint64 {
	return maphash.Bytes(t.seed, s) >> t.shift
}

// appendRows appends the active rows of b with their keys to the table and
// returns the bytes of string data added.
func (t *joinTable) appendRows(b *Batch, keys []*Vec, keyTypes []types.Type, keyBuf *[]byte) int64 {
	var bytes int64
	keyClasses := make([]vclass, len(keys))
	for k, kt := range keyTypes {
		keyClasses[k] = classOf(kt)
	}
	if t.enc == nil {
		t.enc = make([]*buildDict, len(t.classes))
		for k, cls := range t.classes {
			if cls == vStr {
				t.enc[k] = &buildDict{index: map[string]uint32{}}
			}
		}
	}
	// Rows with a NULL key never match: they are not stored.
	rows := t.rows[:0]
	forActive(b.N, b.Sel, func(i int) {
		for _, kv := range keys {
			if kv.isNull(i) {
				return
			}
		}
		rows = append(rows, int32(i))
	})
	t.rows = rows
	n, sel := b.N, rows
	if b.Sel == nil && len(rows) == n {
		sel = nil // all rows: bulk copies
	}
	if t.intKey {
		t.intKeys = appendActive(t.intKeys, keys[0].I, n, sel)
	} else {
		for _, i := range rows {
			kb := (*keyBuf)[:0]
			for k, kv := range keys {
				kb = appendKey(kb, kv.value(int(i), keyClasses[k]), keyTypes[k])
			}
			*keyBuf = kb
			t.strKeys = append(t.strKeys, string(kb))
			bytes += int64(len(kb))
		}
	}
	for k, v := range b.Cols {
		c := &t.cols[k]
		if v.Nulls != nil && c.Nulls == nil {
			c.Nulls = make([]bool, t.n, max(t.n, 16))
		}
		if c.Nulls != nil {
			if v.Nulls != nil {
				c.Nulls = appendActive(c.Nulls, v.Nulls, n, sel)
			} else {
				c.Nulls = append(c.Nulls, make([]bool, len(rows))...)
			}
		}
		switch t.classes[k] {
		case vInt:
			c.I = appendActive(c.I, v.I, n, sel)
		case vFloat:
			c.F = appendActive(c.F, v.F, n, sel)
		case vWide:
			c.W = appendActive(c.W, v.W, n, sel)
		default:
			if d := t.enc[k]; d != nil {
				for _, i := range rows {
					var code uint32
					if !v.isNull(int(i)) {
						code = d.codeOf(v, int(i))
					}
					c.Codes = append(c.Codes, code)
				}
				break
			}
			old := len(c.S)
			c.S = appendActive(c.S, v.strs(n), n, sel)
			for _, str := range c.S[old:] {
				bytes += int64(len(str))
			}
		}
	}
	t.n += len(rows)
	for k, d := range t.enc {
		if d != nil && len(d.dict) > maxBuildDict {
			t.decode(k)
		}
	}
	return bytes
}

// index builds the bucket chains (and finishes dictionary-encoded
// columns).
func (t *joinTable) index() {
	for k, d := range t.enc {
		if d == nil {
			continue
		}
		if len(d.dict) == 0 {
			t.decode(k) // only NULLs (or no rows)
			continue
		}
		t.cols[k].Dict = d.dict
	}
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

// joinBuild is the build side of a hash join: consumed and hashed once, on
// first use, and then shared read-only by every probe operator instance
// (parallel workers probe the same table).
type joinBuild struct {
	ec       *Context
	input    BatchOperator
	keys     *exprSet
	keyTypes []types.Type
	classes  []vclass
	intKey   bool
	once     sync.Once
	table    *joinTable
	err      error
	emitted  atomic.Int64 // output rows of all probe instances (--max-join-rows)
}

// buildSide returns the build input, keys and key types of a hash join.
func buildSide(x *physical.HashJoin) (build, probe physical.Node, buildKeys, probeKeys []plan.Expr) {
	if x.BuildLeft {
		return x.Left, x.Right, x.LeftKeys, x.RightKeys
	}
	return x.Right, x.Left, x.RightKeys, x.LeftKeys
}

func newJoinBuild(ec *Context, x *physical.HashJoin) (*joinBuild, error) {
	buildNode, _, buildKeys, probeKeys := buildSide(x)
	input, err := BuildBatch(ec, buildNode)
	if err != nil {
		return nil, err
	}
	s := &joinBuild{ec: ec, input: input, keyTypes: exprTypes(buildKeys)}
	if s.keys, err = newExprSet(ec, buildNode.Schema(), buildKeys); err != nil {
		return nil, err
	}
	for _, c := range buildNode.Schema() {
		s.classes = append(s.classes, classOf(c.Type))
	}
	kb, kp := s.keyTypes[0], probeKeys[0].Type()
	s.intKey = len(buildKeys) == 1 && classOf(kb) == vInt && classOf(kp) == vInt && kb.Kind == kp.Kind && kb.Scale == kp.Scale
	return s, nil
}

func (s *joinBuild) get() (*joinTable, error) {
	s.once.Do(func() { s.table, s.err = s.build() })
	return s.table, s.err
}

func (s *joinBuild) build() (*joinTable, error) {
	t := &joinTable{seed: maphash.MakeSeed(), classes: s.classes, intKey: s.intKey}
	t.cols = make([]Vec, len(t.classes))
	keys := make([]*Vec, len(s.keyTypes))
	var keyBuf []byte
	for {
		b, err := s.input.NextBatch()
		if err != nil {
			return nil, err
		}
		if b == nil {
			break
		}
		if err := s.ec.Check(); err != nil {
			return nil, err
		}
		if err := s.keys.eval(b, b.Sel, keys); err != nil {
			if rowErr := s.keys.firstError(b); rowErr != nil {
				return nil, rowErr
			}
			return nil, errs.New(errs.InternalError, "vectorized join key evaluation failed: %v", err)
		}
		bytes := t.appendRows(b, keys, s.keyTypes, &keyBuf)
		width := int64(len(t.classes))
		if err := s.ec.Mem.Reserve(int64(b.Len())*(40+16*width) + bytes); err != nil {
			return nil, err
		}
	}
	t.index()
	return t, nil
}

// vhashJoinOp probes a hash join's build table with batches of its probe
// input (INNER and LEFT joins).
type vhashJoinOp struct {
	ec          *Context
	kind        plan.JoinKind
	buildLeft   bool
	anti        bool // emit unmatched probe rows only (physical.HashJoin.Anti)
	shared      *joinBuild
	probe       BatchOperator
	probeKeys   *exprSet
	keyTypesP   []types.Type
	keyClassesP []vclass
	residual    *exprSet // over the output layout; nil if none
	table       *joinTable

	// probe state
	pb         *Batch
	pbuf       Batch
	pkeys      []*Vec
	active     int // number of active probe rows to process
	pos        int // index (into the active rows) of the current probe row
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
	pending      error
}

// buildVHashJoin builds a hash join; inside a parallel pipeline (pc
// non-nil) the probe input continues the pipeline and the build side is
// shared by all workers.
func buildVHashJoin(ec *Context, x *physical.HashJoin, pc *pipelineCtx) (BatchOperator, error) {
	var shared *joinBuild
	var err error
	if pc != nil {
		shared, err = pc.joinBuild(ec, x)
	} else {
		shared, err = newJoinBuild(ec, x)
	}
	if err != nil {
		return nil, err
	}
	_, probeNode, _, probeKeys := buildSide(x)
	probe, err := buildPipelineInput(ec, probeNode, pc)
	if err != nil {
		return nil, err
	}
	op := &vhashJoinOp{ec: ec, kind: x.Kind, buildLeft: x.BuildLeft, anti: x.Anti, shared: shared, probe: probe}
	if op.probeKeys, err = newExprSet(ec, probeNode.Schema(), probeKeys); err != nil {
		return nil, err
	}
	op.keyTypesP = exprTypes(probeKeys)
	for _, t := range op.keyTypesP {
		op.keyClassesP = append(op.keyClassesP, classOf(t))
	}
	if x.Residual != nil {
		if op.residual, err = newExprSet(ec, x.Schema(), []plan.Expr{x.Residual}); err != nil {
			return nil, err
		}
	}
	for _, c := range x.Schema() {
		op.outCols = append(op.outCols, classOf(c.Type))
	}
	op.bufs = make([]vecBuf, len(op.outCols))
	op.codes = make([][]uint32, len(op.outCols))
	op.out.Cols = make([]*Vec, len(op.outCols))
	op.pkeys = make([]*Vec, len(probeKeys))
	return op, nil
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
	if j.anti {
		j.fillUnmatched()
		return
	}
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
						j.keyBuf = appendKey(j.keyBuf, kv.value(i, j.keyClassesP[k]), j.keyTypesP[k])
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

// fillUnmatched collects up to BatchSize unmatched probe rows (paired with
// build row -1) of the current probe batch (anti joins). The matched rows
// the join would have produced still count for --max-join-rows.
func (j *vhashJoinOp) fillUnmatched() {
	t := j.table
	pp, pbuild := j.pairP[:0], j.pairB[:0]
	var matches int64
	defer func() {
		if limit := j.ec.MaxJoinRows; limit > 0 && matches > 0 && j.shared.emitted.Add(matches) > limit {
			j.pending = errs.New(errs.ResourceLimit, "join produced more than %d rows", limit)
		}
	}()
	for ; j.pos < j.active && len(pp) < BatchSize && j.pending == nil; j.pos++ {
		i := j.rowAt(j.pos)
		hasNull := false
		for _, kv := range j.pkeys {
			hasNull = hasNull || kv.isNull(i)
		}
		matched := false
		switch {
		case hasNull:
		case t.intKey:
			k := j.pkeys[0].I[i]
			for c := t.heads[hashInt(k, t.shift)]; c >= 0; c = t.next[c] {
				if t.intKeys[c] == k {
					matched = true
					matches++
				}
			}
		default:
			j.keyBuf = j.keyBuf[:0]
			for k, kv := range j.pkeys {
				j.keyBuf = appendKey(j.keyBuf, kv.value(i, j.keyClassesP[k]), j.keyTypesP[k])
			}
			for c := t.heads[t.bucketOfString(j.keyBuf)]; c >= 0; c = t.next[c] {
				if t.strKeys[c] == string(j.keyBuf) {
					matched = true
					matches++
				}
			}
		}
		if !matched {
			pp, pbuild = append(pp, int32(i)), append(pbuild, -1)
		}
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
		gatherInts(j.ec.Native, v.I, idx, out.I)
	case cls == vFloat:
		for o, i := range idx {
			out.F[o] = v.F[i]
		}
	case cls == vWide:
		for o, i := range idx {
			out.W[o] = v.W[i]
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
	if v.Dict != nil {
		// Dictionary-encoded build column: gather codes.
		codes := grow(j.codes[k], n)
		j.codes[k] = codes
		for o, b := range idx {
			if b < 0 || (v.Nulls != nil && v.Nulls[b]) {
				codes[o] = 0
				nulls[o] = true
				continue
			}
			codes[o] = v.Codes[b]
		}
		out.S = out.S[:0]
		out.Dict, out.Codes = v.Dict, codes
		return out
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
		case vWide:
			out.W[o] = v.W[b]
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
	} else if j.residual.out[0] == vInt {
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
	if j.table == nil {
		t, err := j.shared.get()
		if err != nil {
			return nil, err
		}
		j.table = t
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
			if j.pending != nil {
				err := j.pending
				j.pending = nil
				return nil, err
			}
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
	emitted := j.shared.emitted.Load()
	if limit := j.ec.MaxJoinRows; limit > 0 && emitted+n > limit {
		allowed := limit - emitted
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
	j.shared.emitted.Add(n)
	return b, nil
}
