// Package exec executes physical plans with a pull-based (Volcano) operator
// tree. Expressions are compiled into closures against the row layout of the
// operator evaluating them.
package exec

import (
	"context"
	"errors"
	"sync/atomic"

	"polyquery/internal/errs"
	"polyquery/internal/physical"
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Context carries per-query execution state.
type Context struct {
	Ctx         context.Context
	Mem         *MemTracker
	MaxJoinRows int64 // ≤ 0 = unlimited
	Plan        *physical.Plan
	// Vectorized selects batch execution (mode "vectorized").
	Vectorized bool
	// Threads is the number of worker goroutines for parallel scans and
	// aggregations (≤ 1: serial execution).
	Threads int
	// MorselRows is the number of rows per parallel work unit (0: default).
	MorselRows int

	// serial > 0 while building plans evaluated per outer row (correlated
	// subqueries), which never use parallel workers.
	serial int

	// params holds the current values of outer columns referenced by the
	// correlated subquery being built (column ID → cell).
	params map[plan.ColumnID]*types.Value
	// subCache memoizes uncorrelated subquery results.
	subCache map[*plan.Subquery]*subResult
	// lookups and cached hold the per-query state of ParamLookup and
	// Materialize nodes of correlated subquery plans.
	lookups map[*physical.ParamLookup]*lookupTable
	cached  map[*physical.Materialize][]types.Row
}

// checkEvery is how many rows operators process between cancellation checks.
const checkEvery = 4096

// Check returns TIMEOUT/CANCELLED if the query's context is done.
func (c *Context) Check() error {
	if err := c.Ctx.Err(); err != nil {
		return ContextError(err)
	}
	return nil
}

// ContextError maps a context error to a PolyQuery error.
func ContextError(err error) error {
	if errors.Is(err, context.DeadlineExceeded) {
		return errs.New(errs.Timeout, "query exceeded its timeout")
	}
	return errs.New(errs.Cancelled, "query was cancelled")
}

// MemTracker approximates the memory retained by a query's operators. It
// is safe for concurrent use by parallel workers.
type MemTracker struct {
	Limit int64 // bytes; ≤ 0 = unlimited
	used  atomic.Int64
}

// Reserve accounts n more bytes, failing with RESOURCE_LIMIT past the budget.
func (m *MemTracker) Reserve(n int64) error {
	if m == nil {
		return nil
	}
	if used := m.used.Add(n); m.Limit > 0 && used > m.Limit {
		return errs.New(errs.ResourceLimit, "query exceeded its memory budget of %d MiB", m.Limit>>20)
	}
	return nil
}

// Mark returns the current usage, for a later Reset.
func (m *MemTracker) Mark() int64 {
	if m == nil {
		return 0
	}
	return m.used.Load()
}

// Reset restores the usage recorded by Mark (memory of finished operators).
func (m *MemTracker) Reset(mark int64) {
	if m != nil {
		m.used.Store(mark)
	}
}

// RowSize estimates the retained size of a row in bytes.
func RowSize(r types.Row) int64 {
	n := int64(24 + 40*len(r))
	for i := range r {
		n += int64(len(r[i].S))
	}
	return n
}

// layout maps column IDs to positions in an operator's input row.
type layout map[plan.ColumnID]int

func layoutOf(cols []plan.Column) layout {
	l := make(layout, len(cols))
	for i, c := range cols {
		l[c.ID] = i
	}
	return l
}
