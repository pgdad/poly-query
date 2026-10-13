// Package analyzer performs semantic analysis (spec/sql/semantics.md): it
// resolves names against the catalog, CTEs and enclosing queries, type-checks
// expressions (inserting implicit promotions), validates aggregation and
// grouping rules and produces a logical plan (package plan).
package analyzer

import (
	"polyquery/internal/errs"
	"polyquery/internal/interrupt"
	"polyquery/internal/plan"
	"polyquery/internal/sql/ast"
	"polyquery/internal/storage"
	"polyquery/internal/types"
)

// Catalog is the read-only view of tables used during analysis.
type Catalog interface {
	Get(name string) (*storage.Table, bool)
}

// Config holds analysis switches.
type Config struct {
	// TestFunctions enables PQ_SLEEP.
	TestFunctions bool
	// EvalConst evaluates a constant expression. It is used for constant
	// function parameters that determine a result type (ROUND digits) or are
	// validated up front (DATE_TRUNC units).
	EvalConst func(plan.Expr) (types.Value, error)
	// Interrupt observes the query's deadline (nil: none).
	Interrupt *interrupt.Checker
}

// AnalyzeQuery validates a query and returns its logical plan. The plan's
// schema carries the output column names.
func AnalyzeQuery(q *ast.Query, cat Catalog, cfg Config) (plan.Node, error) {
	a := &analyzer{cat: cat, cfg: cfg}
	return a.query(q, nil, nil)
}

type analyzer struct {
	cat    Catalog
	cfg    Config
	nextID plan.ColumnID
	subSeq int
}

func (a *analyzer) newColumn(name string, t types.Type) plan.Column {
	a.nextID++
	return plan.Column{ID: a.nextID, Name: name, Type: t}
}

func semanticAt(p ast.Pos, format string, args ...any) error {
	return errs.At(errs.SemanticError, p.Line, p.Col, format, args...)
}

func typeAt(p ast.Pos, format string, args ...any) error {
	return errs.At(errs.TypeError, p.Line, p.Col, format, args...)
}

// ---------------------------------------------------------------- scopes

// rangeVar is a FROM-clause range variable: a named relation whose columns
// are visible to expressions of the query block.
type rangeVar struct {
	name string
	cols []plan.Column
}

// scope holds the range variables of one query block; parent is the scope of
// the enclosing query (for correlated references).
type scope struct {
	parent *scope
	vars   []*rangeVar
}

func (s *scope) add(p ast.Pos, v *rangeVar) error {
	for _, o := range s.vars {
		if storage.EqualFold(o.name, v.name) {
			return semanticAt(p, "duplicate table name or alias %q in FROM", v.name)
		}
	}
	s.vars = append(s.vars, v)
	return nil
}

// inputIDs returns the IDs of all columns of the block's range variables.
func (s *scope) inputIDs() map[plan.ColumnID]bool {
	ids := map[plan.ColumnID]bool{}
	for _, v := range s.vars {
		for _, c := range v.cols {
			ids[c.ID] = true
		}
	}
	return ids
}

// cteDef is a WITH entry together with the environment it was defined in.
type cteDef struct {
	def   *ast.CTE
	env   *cteEnv // CTEs visible inside the definition
	outer *scope  // enclosing query scope at the definition
}

// cteEnv is an immutable linked list of visible CTEs, innermost first.
type cteEnv struct {
	def    *cteDef
	parent *cteEnv
}

func (e *cteEnv) lookup(name string) *cteDef {
	for ; e != nil; e = e.parent {
		if storage.EqualFold(e.def.def.Name, name) {
			return e.def
		}
	}
	return nil
}
