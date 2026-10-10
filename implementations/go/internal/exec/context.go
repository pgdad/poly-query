// Package exec executes logical plans with a pull-based (Volcano) operator
// tree. Expressions are compiled into closures once per query.
package exec

import (
	"context"
	"errors"

	"polyquery/internal/errs"
	"polyquery/internal/types"
)

// Context carries per-query execution state.
type Context struct {
	Ctx context.Context
	Mem *MemTracker
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

// MemTracker approximates the memory retained by a query's operators.
type MemTracker struct {
	Limit int64 // bytes; ≤ 0 = unlimited
	used  int64
}

// Reserve accounts n more bytes, failing with RESOURCE_LIMIT past the budget.
func (m *MemTracker) Reserve(n int64) error {
	if m == nil {
		return nil
	}
	m.used += n
	if m.Limit > 0 && m.used > m.Limit {
		return errs.New(errs.ResourceLimit, "query exceeded its memory budget of %d MiB", m.Limit>>20)
	}
	return nil
}

// RowSize estimates the retained size of a row in bytes.
func RowSize(r types.Row) int64 {
	n := int64(24 + 40*len(r))
	for i := range r {
		n += int64(len(r[i].S))
	}
	return n
}
