package parser

import (
	"polyquery/internal/errs"
	"polyquery/internal/interrupt"
)

// Limits are the statement size limits of change request CR-6
// (spec/changes/expression-limits.md). A statement beyond one of them
// fails with RESOURCE_LIMIT naming the measure; the check stops parsing
// early, so recursion, memory and time stay bounded for any input.
type Limits struct {
	// MaxTextBytes bounds the SQL text length in bytes.
	MaxTextBytes int
	// MaxDepth bounds the expression nesting depth: the largest number of
	// enclosing constructs around any expression, where a chain of binary
	// operators of one precedence level counts as one level (CR-6 §1).
	MaxDepth int
	// MaxOperands bounds the number of literals, column references and
	// `*` arguments in the statement.
	MaxOperands int
}

// DefaultLimits are the engine's limits: well above the CR-6 minimums
// (1 MiB, depth 1,000, 25,000 operands) and low enough that every stage,
// including recursive passes over a left-deep chain of MaxOperands terms
// in parallel workers, stays within the goroutine stack limit and runs in
// a few seconds.
var DefaultLimits = Limits{
	MaxTextBytes: 16 << 20,
	MaxDepth:     4096,
	MaxOperands:  250_000,
}

// Options configure Parse.
type Options struct {
	Limits Limits
	// Interrupt bounds the parse: the query's deadline or cancellation
	// stops it with TIMEOUT or CANCELLED (nil: no bound).
	Interrupt *interrupt.Checker
}

func (p *parser) textLimit(n int) error {
	if max := p.limits.MaxTextBytes; max > 0 && n > max {
		return p.fail(errs.New(errs.ResourceLimit, "statement text length %d bytes exceeds %d", n, max))
	}
	return nil
}

// enter opens a nesting construct around what is parsed until leave. The
// number of open constructs never exceeds the nesting depth of the
// statement, so failing here never rejects a statement within the limit;
// it bounds the parser's recursion before the exact measure (the heights
// returned by the expression parsers) is known.
func (p *parser) enter() error {
	p.open++
	if max := p.limits.MaxDepth; max > 0 && p.open > max {
		return p.depthError()
	}
	return nil
}

func (p *parser) leave() { p.open-- }

// level returns the nesting height of a construct whose operands have the
// given maximum height, failing beyond the depth limit.
func (p *parser) level(inner int) (int, error) {
	h := inner + 1
	if max := p.limits.MaxDepth; max > 0 && h > max {
		return h, p.depthError()
	}
	return h, nil
}

func (p *parser) depthError() error {
	return p.fail(errs.New(errs.ResourceLimit, "expression nesting depth exceeds %d", p.limits.MaxDepth))
}

// operand counts one literal, column reference or `*` argument.
func (p *parser) operand() error {
	p.operands++
	if max := p.limits.MaxOperands; max > 0 && p.operands > max {
		return p.fail(errs.New(errs.ResourceLimit, "operand count exceeds %d", max))
	}
	return nil
}

// joinNesting guards the recursion of parenthesized FROM items, which the
// nesting depth does not count.
func (p *parser) enterJoin() error {
	p.joinOpen++
	if max := p.limits.MaxDepth; max > 0 && p.joinOpen > max {
		return p.fail(errs.New(errs.ResourceLimit, "join nesting depth exceeds %d", max))
	}
	return nil
}

func (p *parser) leaveJoin() { p.joinOpen-- }

// fail records an error that ends the parse whatever the parser does
// next: a limit, a lexical error, a timeout. From then on the token
// stream is at its end, and Parse reports this error.
func (p *parser) fail(err error) error {
	if p.fatal == nil {
		p.fatal = err
	}
	return p.fatal
}

// note records the height of a clause expression of the current query.
func (p *parser) note(h int) {
	if h > p.queryHeight {
		p.queryHeight = h
	}
}
