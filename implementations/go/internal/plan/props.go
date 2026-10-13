package plan

// Props answers structural questions about the subexpressions of an
// expression tree, computing each node's answer once. Passes that ask at
// every node of a tree (constant folding, vector compilation) stay linear
// in its size instead of quadratic: a 10,000-term OR chain is a binary tree
// of depth 10,000 (spec/changes/expression-limits.md).
//
// Nodes are identified by pointer, so a Props must only be used on trees
// that are not mutated in place while it is in use.
type Props struct {
	m map[Expr]propBits
}

type propBits uint8

const (
	propKnown propBits = 1 << iota
	propColumn
	propAgg
	propSubquery
	propSleep
)

// NewProps returns an empty property cache.
func NewProps() *Props { return &Props{m: map[Expr]propBits{}} }

func (p *Props) bits(e Expr) propBits {
	if e == nil {
		return 0
	}
	if b, ok := p.m[e]; ok {
		return b
	}
	b := propKnown
	switch x := e.(type) {
	case *ColumnRef:
		b |= propColumn
	case *AggCall:
		b |= propAgg
	case *Subquery:
		b |= propSubquery
	case *Func:
		if x.Name == "PQ_SLEEP" {
			b |= propSleep
		}
	}
	for _, c := range Children(e) {
		b |= p.bits(c)
	}
	p.m[e] = b
	return b
}

// IsConstant is IsConstant(e), memoized.
func (p *Props) IsConstant(e Expr) bool {
	return p.bits(e)&(propColumn|propAgg|propSubquery) == 0
}

// Volatile reports whether e calls PQ_SLEEP (whose evaluation count is
// observable).
func (p *Props) Volatile(e Expr) bool { return p.bits(e)&propSleep != 0 }

// Movable reports whether e contains no subquery, aggregate or PQ_SLEEP
// call, so that it may be evaluated at another place or time.
func (p *Props) Movable(e Expr) bool {
	return p.bits(e)&(propAgg|propSubquery|propSleep) == 0
}
