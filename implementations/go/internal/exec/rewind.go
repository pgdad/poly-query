package exec

// Rewinding lets a correlated subquery plan be built once and re-executed
// for every distinct combination of outer values: rewind resets an
// operator (and its inputs) to its state right after Build. Expressions
// read outer values through parameter cells that stay the same for all
// executions (see compileSubquery), so a rewound tree computes exactly
// what a newly built one would. rewind reports false if some operator of
// the tree cannot be rewound; the caller then builds a new tree.

type rewinder interface {
	rewind() bool
}

func rewindOp(op Operator) bool {
	r, ok := op.(rewinder)
	return ok && r.rewind()
}

func (f *filterOp) rewind() bool  { return rewindOp(f.input) }
func (p *projectOp) rewind() bool { return rewindOp(p.input) }

func (l *limitOp) rewind() bool {
	l.offset, l.seen = l.offset0, 0
	return rewindOp(l.input)
}

func (o *paramLookupOp) rewind() bool {
	o.started, o.pos, o.matches = false, 0, nil
	return true
}

func (r *replayOp) rewind() bool {
	r.pos = 0
	return true
}

func (v *valuesOp) rewind() bool {
	v.pos = 0
	return true
}

func (a *hashAggregateOp) rewind() bool {
	a.out, a.pos, a.done = nil, 0, false
	return rewindOp(a.input)
}

func (s *sortOp) rewind() bool {
	s.rows, s.pos, s.done = nil, 0, false
	return rewindOp(s.input)
}

func (d *distinctOp) rewind() bool {
	clear(d.seen)
	return rewindOp(d.input)
}
