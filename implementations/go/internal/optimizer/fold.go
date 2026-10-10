package optimizer

import (
	"polyquery/internal/plan"
	"polyquery/internal/types"
)

// Constant folding and predicate simplification.
//
// Every maximal constant subexpression (no column references, subqueries
// or aggregates, and no PQ_SLEEP) is evaluated once at planning time and
// replaced by a literal of the same type. An expression whose evaluation
// fails is left alone, so the error is raised (or not) exactly as without
// folding — e.g. 1/0 in the select list of an empty table never fails.
//
// Boolean connectives with a constant operand are then simplified where
// that cannot change results or errors: TRUE AND x ⇒ x, x AND TRUE ⇒ x,
// FALSE AND x ⇒ FALSE (x is never evaluated), and dually for OR. x AND FALSE
// is kept: x is evaluated first and may raise an error. Filters whose
// predicate became TRUE disappear during predicate pushdown.

func foldPlan(n plan.Node, eval EvalFunc) plan.Node {
	if eval == nil {
		return n
	}
	return plan.MapExprs(n, func(e plan.Expr) plan.Expr {
		if _, ok := e.(*plan.Subquery); ok {
			return nil // MapExprs folds inside the subquery plan
		}
		return simplify(foldExpr(e, eval))
	})
}

// foldExpr replaces the maximal constant subexpressions of e by literals.
func foldExpr(e plan.Expr, eval EvalFunc) plan.Expr {
	return plan.Map(e, func(x plan.Expr) plan.Expr {
		switch x.(type) {
		case *plan.Literal, *plan.ColumnRef:
			return x
		case *plan.Subquery:
			return nil
		}
		if !plan.IsConstant(x) || !movable(x) {
			return nil
		}
		v, err := eval(x)
		if err != nil {
			return nil // keep: the error must surface only when evaluated
		}
		return &plan.Literal{Val: v, T: x.Type()}
	})
}

func boolLiteral(e plan.Expr) (value, ok bool) {
	l, isLit := e.(*plan.Literal)
	if !isLit || l.Val.Null || l.T.Kind != types.KindBoolean {
		return false, false
	}
	return l.Val.I != 0, true
}

func isTrue(e plan.Expr) bool {
	v, ok := boolLiteral(e)
	return ok && v
}

// simplify removes constant operands of AND/OR (bottom-up).
func simplify(e plan.Expr) plan.Expr {
	return plan.Map(e, func(x plan.Expr) plan.Expr {
		b, ok := x.(*plan.Binary)
		if !ok || (b.Op != plan.OpAnd && b.Op != plan.OpOr) {
			return nil
		}
		l, r := simplify(b.L), simplify(b.R)
		absorbing := b.Op == plan.OpOr // TRUE for OR, FALSE for AND
		isBool := func(e plan.Expr) bool { return e.Type().Kind == types.KindBoolean }
		if v, ok := boolLiteral(l); ok {
			if v == absorbing {
				return l
			}
			if isBool(r) {
				return r
			}
		}
		if v, ok := boolLiteral(r); ok && v != absorbing && isBool(l) {
			return l
		}
		return &plan.Binary{Op: b.Op, L: l, R: r, T: b.T}
	})
}
