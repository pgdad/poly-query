package exec

import (
	"sync"

	"polyquery/internal/physical"
	"polyquery/internal/types"
)

// sharedResult holds the rows of a shared aggregation (see
// physical.Plan.Shared), computed by the first occurrence that runs.
type sharedResult struct {
	once sync.Once
	rows []types.Row
	err  error
}

// sharedRows returns the rows of the shared aggregation x, computing them
// with build on first use. Occurrences may run on different goroutines
// (e.g. a hash join build side taken by a parallel worker).
func (ec *Context) sharedRows(x *physical.HashAggregate, build func() (Operator, error)) ([]types.Row, error) {
	key := ec.Plan.Shared[x]
	ec.sharedMu.Lock()
	r := ec.shared[key]
	if r == nil {
		if ec.shared == nil {
			ec.shared = map[string]*sharedResult{}
		}
		r = &sharedResult{}
		ec.shared[key] = r
	}
	ec.sharedMu.Unlock()
	r.once.Do(func() {
		op, err := build()
		if err != nil {
			r.err = err
			return
		}
		r.rows, r.err = materialize(ec, op)
	})
	return r.rows, r.err
}

// isShared reports whether x is an aggregation shared by several
// occurrences in the statement.
func (ec *Context) isShared(x *physical.HashAggregate) bool {
	if ec.Plan == nil {
		return false
	}
	_, ok := ec.Plan.Shared[x]
	return ok
}
