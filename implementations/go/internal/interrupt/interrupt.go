// Package interrupt lets every stage of a query (parsing, analysis,
// optimization, planning, execution) observe the query's deadline and
// cancellation cheaply: the timeout covers the whole life of a query
// (spec/changes/expression-limits.md §4).
package interrupt

import (
	"context"
	"errors"
	"sync/atomic"

	"polyquery/internal/errs"
)

// ticksPerCheck is how many Tick calls pass between two looks at the
// context (a look takes a lock).
const ticksPerCheck = 256

// Checker observes a context. A nil *Checker never interrupts. It is safe
// for concurrent use.
type Checker struct {
	ctx   context.Context
	ticks atomic.Uint32
}

// New returns a checker for ctx (nil if ctx is nil).
func New(ctx context.Context) *Checker {
	if ctx == nil {
		return nil
	}
	return &Checker{ctx: ctx}
}

// Context returns the observed context (context.Background for nil).
func (c *Checker) Context() context.Context {
	if c == nil {
		return context.Background()
	}
	return c.ctx
}

// Check returns TIMEOUT or CANCELLED if the context is done.
func (c *Checker) Check() error {
	if c == nil {
		return nil
	}
	if err := c.ctx.Err(); err != nil {
		return Error(err)
	}
	return nil
}

// Tick counts one unit of work and checks the context every
// ticksPerCheck units. Call it inside loops and recursions whose work
// grows with the size of the statement.
func (c *Checker) Tick() error {
	if c == nil {
		return nil
	}
	if c.ticks.Add(1)%ticksPerCheck != 0 {
		return nil
	}
	return c.Check()
}

// Error converts the error of a done context into TIMEOUT or CANCELLED.
func Error(err error) error {
	if errors.Is(err, context.DeadlineExceeded) {
		return errs.New(errs.Timeout, "query exceeded its timeout")
	}
	return errs.New(errs.Cancelled, "query was cancelled")
}
