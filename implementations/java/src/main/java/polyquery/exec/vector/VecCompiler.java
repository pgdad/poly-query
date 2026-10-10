package polyquery.exec.vector;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import polyquery.common.PolyQueryException;
import polyquery.exec.ExecContext;
import polyquery.exec.ExpressionCompiler;
import polyquery.physical.ColumnPruner;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExpr.CompareOp;
import polyquery.plan.BoundExprs;
import polyquery.types.DataType;
import polyquery.types.TypeKind;

/**
 * Compiles bound expressions into batch kernels ({@link Kernels}). Constant subexpressions are
 * folded once; constructs without a kernel are evaluated row by row with the row engine's
 * compiled code, so every expression is supported with identical semantics.
 */
final class VecCompiler {
    private static final Object[] NO_ROW = new Object[0];

    private final ExecContext ctx;
    private final ExpressionCompiler rows;
    /** Holder of the shared operand while compiling the expressions that read it. */
    private Kernels.Operand operand;

    VecCompiler(ExecContext ctx, ExpressionCompiler rows) {
        this.ctx = ctx;
        this.rows = rows;
    }

    ExpressionCompiler rowCompiler() {
        return rows;
    }

    VecExpr compile(BoundExpr e) {
        if (!(e instanceof BoundExpr.Literal) && foldable(e)) {
            try {
                return new Kernels.Constant(e.type(), rows.compile(e).eval(NO_ROW));
            } catch (PolyQueryException ex) {
                // not folded: the error is raised when (and if) a row evaluates it
            }
        }
        return switch (e) {
            case BoundExpr.ColumnRef c -> new Kernels.ColumnRef(c.index());
            case BoundExpr.AggregateRef a -> new Kernels.ColumnRef(a.index());
            case BoundExpr.OuterRef o -> new Kernels.OuterRef(ctx, o.frame(), o.index(), o.type());
            case BoundExpr.Placeholder p -> {
                if (operand == null) {
                    throw new IllegalStateException("placeholder outside of its operand context");
                }
                yield operand;
            }
            case BoundExpr.Literal l -> new Kernels.Constant(l.type(), l.value());
            case BoundExpr.Cast c -> cast(c);
            case BoundExpr.Negate n -> n.type().isNumeric() ? new Kernels.Negate(compile(n.input()), n.type())
                    : new Kernels.Constant(n.type(), null);
            case BoundExpr.Not n -> new Kernels.Not(compile(n.input()));
            case BoundExpr.IsNull n -> new Kernels.IsNull(compile(n.input()), n.negated());
            case BoundExpr.And a -> new Kernels.AndOr(true, compile(a.left()), compile(a.right()));
            case BoundExpr.Or o -> new Kernels.AndOr(false, compile(o.left()), compile(o.right()));
            case BoundExpr.Concat c -> new Kernels.Concat(compile(c.left()), compile(c.right()));
            case BoundExpr.Arithmetic a -> arithmetic(a);
            case BoundExpr.Comparison c -> comparison(c);
            case BoundExpr.Like l -> like(l);
            case BoundExpr.InList i -> inList(i);
            case BoundExpr.Between b -> between(b);
            case BoundExpr.Case c -> caseExpr(c);
            case BoundExpr.NullIf n -> {
                VecExpr value = compile(n.operand());
                Kernels.Operand holder = new Kernels.Operand();
                yield new Kernels.NullIf(value, holder, withOperand(holder, n.equality()), n.type());
            }
            case BoundExpr.Function f -> function(f);
            case BoundExpr.ScalarSubquery s -> rowEval(e);
            case BoundExpr.Exists x -> rowEval(e);
            case BoundExpr.InSubquery i -> rowEval(e);
        };
    }

    /** True if {@code e} reads no row, frame or operand and has no side effects. */
    private static boolean foldable(BoundExpr e) {
        return !BoundExprs.any(e, x -> x instanceof BoundExpr.ColumnRef || x instanceof BoundExpr.AggregateRef
                || x instanceof BoundExpr.OuterRef || x instanceof BoundExpr.Placeholder
                || BoundExprs.subqueryOf(x) != null
                || x instanceof BoundExpr.Function f && f.name().equals("PQ_SLEEP"));
    }

    private VecExpr withOperand(Kernels.Operand holder, BoundExpr e) {
        Kernels.Operand saved = operand;
        operand = holder;
        try {
            return compile(e);
        } finally {
            operand = saved;
        }
    }

    /** Row-at-a-time evaluation of {@code e} (no kernel available). */
    private VecExpr rowEval(BoundExpr e) {
        if (BoundExprs.any(e, x -> x instanceof BoundExpr.Placeholder)) {
            // also reads the enclosing shared operand: pass its value through a placeholder cell
            Object[] cell = new Object[1];
            return new Kernels.RowEval(rows.compileWithOperand(e, cell), ColumnPruner.references(e), e.type(), operand,
                    cell);
        }
        return new Kernels.RowEval(rows.compile(e), ColumnPruner.references(e), e.type(), null, null);
    }

    /**
     * Applies row-level code to one vectorized input: {@code template} is {@code e} with that
     * input replaced by a placeholder.
     */
    private VecExpr boxedUnary(BoundExpr input, BoundExpr template, boolean strict, DataType type) {
        Object[] cell = new Object[1];
        boolean deterministic = !BoundExprs.any(template, x -> x instanceof BoundExpr.Function f
                && f.name().equals("PQ_SLEEP"));
        return new Kernels.BoxedUnary(compile(input), cell, rows.compileWithOperand(template, cell), strict,
                deterministic, type);
    }

    private VecExpr cast(BoundExpr.Cast c) {
        DataType from = c.input().type();
        DataType to = c.type();
        if (from.equals(to)) {
            return compile(c.input());
        }
        if (Kernels.PrimitiveCast.supports(from, to)) {
            return new Kernels.PrimitiveCast(compile(c.input()), from, to);
        }
        return boxedUnary(c.input(), new BoundExpr.Cast(new BoundExpr.Placeholder(from), to, c.implicit()), true, to);
    }

    private VecExpr arithmetic(BoundExpr.Arithmetic a) {
        VecExpr l = compile(a.left());
        VecExpr r = compile(a.right());
        return switch (a.type().kind()) {
            case INT64 -> new Kernels.LongArith(a.op(), l, r);
            case DECIMAL -> new Kernels.DecimalArith(a.op(), l, r, a.left().type().scale(), a.right().type().scale(),
                    a.type());
            case FLOAT64 -> new Kernels.DoubleArith(a.op(), l, r);
            default -> new Kernels.Constant(a.type(), null);
        };
    }

    private static CompareOp flip(CompareOp op) {
        return switch (op) {
            case LT -> CompareOp.GT;
            case LE -> CompareOp.GE;
            case GT -> CompareOp.LT;
            case GE -> CompareOp.LE;
            default -> op;
        };
    }

    private VecExpr comparison(BoundExpr.Comparison c) {
        DataType lt = c.left().type();
        DataType rt = c.right().type();
        if (lt.isNull() || rt.isNull()) {
            return new Kernels.Constant(DataType.BOOLEAN, null);
        }
        Vec.Kind lk = Vec.kindOf(lt);
        if (lk != Vec.kindOf(rt)) {
            return rowEval(c);
        }
        CompareOp op = c.op();
        BoundExpr left = c.left();
        BoundExpr right = c.right();
        if (left instanceof BoundExpr.Literal && !(right instanceof BoundExpr.Literal)) {
            BoundExpr t = left;
            left = right;
            right = t;
            op = flip(op);
            DataType tt = lt;
            lt = rt;
            rt = tt;
        }
        VecExpr l = compile(left);
        VecExpr r = compile(right);
        if (lt.kind() == TypeKind.DECIMAL && rt.kind() == TypeKind.DECIMAL && lt.scale() != rt.scale()) {
            return new Kernels.DecimalCompare(op, l, r, lt.scale(), rt.scale());
        }
        return switch (lk) {
            case LONG -> new Kernels.LongCompare(op, l, r);
            case DOUBLE -> new Kernels.DoubleCompare(op, l, r);
            default -> new Kernels.StringCompare(op, l, r,
                    right instanceof BoundExpr.Literal lit ? (String) lit.value() : null);
        };
    }

    private VecExpr like(BoundExpr.Like l) {
        if (l.pattern() instanceof BoundExpr.Literal lit) {
            if (lit.value() == null) {
                return new Kernels.Constant(DataType.BOOLEAN, null);
            }
            return new Kernels.Like(compile(l.operand()), (String) lit.value(), l.negated());
        }
        return rowEval(l);
    }

    /** A literal in the representation of a vector of {@code type} (as used for set membership). */
    private static Object vecValue(Object v, DataType type) {
        return switch (Vec.kindOf(type)) {
            case LONG -> switch (v) {
                case Boolean b -> b ? 1L : 0L;
                case Integer i -> (long) i;
                default -> v;
            };
            case DOUBLE -> (Double) v == 0.0 ? 0.0 : v;
            default -> v;
        };
    }

    private VecExpr inList(BoundExpr.InList in) {
        DataType t = in.operand().type();
        if (!t.isNull()) {
            Set<Object> values = new HashSet<>();
            boolean hasNull = false;
            boolean constant = true;
            for (BoundExpr c : in.comparisons()) {
                if (!(c instanceof BoundExpr.Comparison cmp && cmp.left() instanceof BoundExpr.Placeholder
                        && cmp.right() instanceof BoundExpr.Literal lit)) {
                    constant = false;
                    break;
                }
                if (lit.value() == null) {
                    hasNull = true;
                } else if (lit.type().kind() != t.kind() || lit.type().scale() != t.scale()) {
                    constant = false;
                    break;
                } else {
                    values.add(vecValue(lit.value(), t));
                }
            }
            if (constant) {
                return new Kernels.InSet(compile(in.operand()), values, hasNull, in.negated());
            }
        }
        VecExpr value = compile(in.operand());
        Kernels.Operand holder = new Kernels.Operand();
        List<VecExpr> cmps = new ArrayList<>();
        for (BoundExpr c : in.comparisons()) {
            cmps.add(withOperand(holder, c));
        }
        return new Kernels.InList(value, holder, cmps.toArray(new VecExpr[0]), in.negated());
    }

    private VecExpr between(BoundExpr.Between b) {
        VecExpr value = compile(b.operand());
        Kernels.Operand holder = new Kernels.Operand();
        VecExpr bounds = new Kernels.AndOr(true, withOperand(holder, b.lower()), withOperand(holder, b.upper()));
        return new Kernels.Between(value, holder, bounds, b.negated());
    }

    private VecExpr caseExpr(BoundExpr.Case c) {
        VecExpr[] results = compileAll(c.results());
        VecExpr otherwise = c.elseResult() == null ? new Kernels.Constant(c.type(), null) : compile(c.elseResult());
        if (c.operand() == null) {
            return new Kernels.Case(null, null, compileAll(c.conditions()), results, otherwise, c.type());
        }
        VecExpr value = compile(c.operand());
        Kernels.Operand holder = new Kernels.Operand();
        VecExpr[] conds = new VecExpr[c.conditions().size()];
        for (int i = 0; i < conds.length; i++) {
            conds[i] = withOperand(holder, c.conditions().get(i));
        }
        return new Kernels.Case(value, holder, conds, results, otherwise, c.type());
    }

    /**
     * Scalar functions: the row implementation applied to one vectorized argument when all other
     * arguments are literals; otherwise (and for the lazy COALESCE) row-at-a-time evaluation.
     */
    private VecExpr function(BoundExpr.Function f) {
        int variable = -1;
        for (int i = 0; i < f.args().size(); i++) {
            if (!(f.args().get(i) instanceof BoundExpr.Literal)) {
                if (variable >= 0) {
                    return rowEval(f);
                }
                variable = i;
            }
        }
        if (variable < 0 || f.name().equals("COALESCE")
                || BoundExprs.any(f, x -> x instanceof BoundExpr.Placeholder)) {
            return rowEval(f);
        }
        List<BoundExpr> args = new ArrayList<>(f.args());
        BoundExpr input = args.get(variable);
        args.set(variable, new BoundExpr.Placeholder(input.type()));
        return boxedUnary(input, new BoundExpr.Function(f.name(), args, f.type()), false, f.type());
    }

    private VecExpr[] compileAll(List<BoundExpr> exprs) {
        VecExpr[] out = new VecExpr[exprs.size()];
        for (int i = 0; i < out.length; i++) {
            out[i] = compile(exprs.get(i));
        }
        return out;
    }
}
