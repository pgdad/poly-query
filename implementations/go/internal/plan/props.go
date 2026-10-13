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
	m map[Expr]nodeProps
}

type nodeProps struct {
	bits propBits
	size int // number of nodes in the subtree
}

type propBits uint8

const (
	propColumn propBits = 1 << iota
	propAgg
	propSubquery
	propSleep
)

// NewProps returns an empty property cache.
func NewProps() *Props { return &Props{m: map[Expr]nodeProps{}} }

func (p *Props) bits(e Expr) propBits { return p.of(e).bits }

func (p *Props) of(e Expr) nodeProps {
	if e == nil {
		return nodeProps{}
	}
	if np, ok := p.m[e]; ok {
		return np
	}
	b, size := propBits(0), 1
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
		cp := p.of(c)
		b |= cp.bits
		size += cp.size
	}
	np := nodeProps{bits: b, size: size}
	p.m[e] = np
	return np
}

// Size returns the number of nodes of e's tree (subquery plans excluded).
// Structurally equal expressions (equal String forms) have equal sizes.
func (p *Props) Size(e Expr) int { return p.of(e).size }

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
