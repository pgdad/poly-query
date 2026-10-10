package polyquery.optimizer;

import java.util.ArrayList;
import java.util.List;
import polyquery.common.PolyQueryException;
import polyquery.exec.ConstantEvaluator;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.LogicalPlan;
import polyquery.types.DataType;
import polyquery.types.TypeKind;

/**
 * Rule-based logical optimization (disabled by {@code optimize: false}):
 *
 * <ul>
 *   <li><b>constant folding</b> — constant subexpressions are evaluated once (unless evaluating
 *       them fails: then the error is raised at run time, by the rows that evaluate them);</li>
 *   <li><b>predicate simplification</b> — {@code TRUE AND x → x}, {@code FALSE AND x → FALSE},
 *       {@code x OR FALSE → x}, …, filters that are always TRUE disappear;</li>
 *   <li><b>predicate pushdown</b> — WHERE conjuncts and join conditions are moved as close to
 *       the scans as semantics allow, and cross joins with a pushed-down join predicate become
 *       inner joins;</li>
 *   <li><b>join reordering</b> of inner-join trees ({@link JoinReorder}).</li>
 * </ul>
 *
 * <p>Every rewrite preserves results <em>and errors</em>: a predicate is only moved if no
 * predicate involved can raise an error ({@link #canFail}), because moving it changes the rows
 * other predicates are evaluated on. Predicates containing correlated subqueries are never
 * moved: their correlation frame is the row layout of the operator they were bound against.
 */
public final class LogicalOptimizer {
    private LogicalOptimizer() {
    }

    public static LogicalPlan optimize(LogicalPlan plan) {
        return JoinReorder.reorder(pushdown(fold(plan)));
    }

    // ------------------------------------------------------------------ folding & simplification

    private static LogicalPlan fold(LogicalPlan plan) {
        return switch (plan) {
            case LogicalPlan.Scan s -> s;
            case LogicalPlan.SingleRow s -> s;
            case LogicalPlan.Filter f -> {
                BoundExpr p = fold(f.predicate());
                LogicalPlan input = fold(f.input());
                yield isTrue(p) ? input : new LogicalPlan.Filter(input, p);
            }
            case LogicalPlan.Join j -> new LogicalPlan.Join(fold(j.left()), fold(j.right()), j.kind(),
                    j.condition() == null ? null : fold(j.condition()));
            case LogicalPlan.Aggregate a -> {
                List<AggregateCall> calls = new ArrayList<>();
                for (AggregateCall c : a.aggregates()) {
                    calls.add(c.argument() == null ? c
                            : new AggregateCall(c.function(), fold(c.argument()), c.distinct(), c.type()));
                }
                yield new LogicalPlan.Aggregate(fold(a.input()), foldAll(a.groupKeys()), calls);
            }
            case LogicalPlan.Project p -> new LogicalPlan.Project(fold(p.input()), foldAll(p.expressions()), p.names());
            case LogicalPlan.Distinct d -> new LogicalPlan.Distinct(fold(d.input()));
            case LogicalPlan.Sort s -> new LogicalPlan.Sort(fold(s.input()), s.keys());
            case LogicalPlan.Limit l -> new LogicalPlan.Limit(fold(l.input()), l.offset(), l.limit());
        };
    }

    private static List<BoundExpr> foldAll(List<BoundExpr> exprs) {
        List<BoundExpr> out = new ArrayList<>(exprs.size());
        for (BoundExpr e : exprs) {
            out.add(fold(e));
        }
        return out;
    }

    private static boolean isTrue(BoundExpr e) {
        return e instanceof BoundExpr.Literal l && Boolean.TRUE.equals(l.value());
    }

    private static boolean isFalse(BoundExpr e) {
        return e instanceof BoundExpr.Literal l && Boolean.FALSE.equals(l.value());
    }

    /** Folds constant subexpressions bottom-up and simplifies AND/OR with constant operands. */
    static BoundExpr fold(BoundExpr e) {
        List<BoundExpr> children = BoundExprs.children(e);
        if (!children.isEmpty()) {
            List<BoundExpr> folded = new ArrayList<>(children.size());
            boolean changed = false;
            for (BoundExpr c : children) {
                BoundExpr f = fold(c);
                changed |= f != c;
                folded.add(f);
            }
            if (changed) {
                e = BoundExprs.withChildren(e, folded);
            }
        }
        if (e instanceof BoundExpr.Literal) {
            return e;
        }
        if (BoundExprs.isConstant(e) && !BoundExprs.any(e, x -> x instanceof BoundExpr.Placeholder)) {
            try {
                return new BoundExpr.Literal(ConstantEvaluator.evaluate(e), e.type());
            } catch (PolyQueryException ex) {
                return e; // raised at run time by the rows that evaluate it (if any)
            }
        }
        return switch (e) {
            // The right operand is only evaluated if the left one does not decide the result.
            case BoundExpr.And a when isTrue(a.left()) -> a.right();
            case BoundExpr.And a when isTrue(a.right()) -> a.left();
            case BoundExpr.And a when isFalse(a.left()) -> a.left();
            case BoundExpr.And a when isFalse(a.right()) && !canFail(a.left()) -> a.right();
            case BoundExpr.Or o when isFalse(o.left()) -> o.right();
            case BoundExpr.Or o when isFalse(o.right()) -> o.left();
            case BoundExpr.Or o when isTrue(o.left()) -> o.left();
            case BoundExpr.Or o when isTrue(o.right()) && !canFail(o.left()) -> o.right();
            case BoundExpr.Not n when n.input() instanceof BoundExpr.Not inner -> inner.input();
            default -> e;
        };
    }

    // ------------------------------------------------------------------ error analysis

    /** Scalar functions that never raise an error for valid arguments. */
    private static final List<String> TOTAL_FUNCTIONS = List.of("UPPER", "LOWER", "TRIM", "LTRIM", "RTRIM", "LENGTH",
            "REPLACE", "CONCAT", "COALESCE", "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND");

    /**
     * Conservative: false only if evaluating {@code e} can never raise an error (overflow,
     * division by zero, conversion, subquery cardinality, …) on any row.
     */
    public static boolean canFail(BoundExpr e) {
        boolean self = switch (e) {
            case BoundExpr.ColumnRef c -> false;
            case BoundExpr.OuterRef o -> false;
            case BoundExpr.Placeholder p -> false;
            case BoundExpr.Literal l -> false;
            case BoundExpr.AggregateRef a -> false;
            case BoundExpr.Not n -> false;
            case BoundExpr.IsNull n -> false;
            case BoundExpr.And a -> false;
            case BoundExpr.Or o -> false;
            case BoundExpr.Comparison c -> false;
            case BoundExpr.Concat c -> false;
            case BoundExpr.Like l -> false;
            case BoundExpr.InList i -> false;
            case BoundExpr.Between b -> false;
            case BoundExpr.Case c -> false;
            case BoundExpr.NullIf n -> false;
            case BoundExpr.Negate n -> n.type().kind() == TypeKind.INT64;
            case BoundExpr.Cast c -> castCanFail(c.input().type(), c.type());
            case BoundExpr.Arithmetic a -> arithmeticCanFail(a);
            case BoundExpr.Function f -> !TOTAL_FUNCTIONS.contains(f.name());
            case BoundExpr.ScalarSubquery s -> true;
            case BoundExpr.Exists x -> true;
            case BoundExpr.InSubquery i -> true;
        };
        if (self) {
            return true;
        }
        for (BoundExpr c : BoundExprs.children(e)) {
            if (canFail(c)) {
                return true;
            }
        }
        return false;
    }

    private static boolean arithmeticCanFail(BoundExpr.Arithmetic a) {
        if (a.type().kind() == TypeKind.INT64 && (a.op() == BoundExpr.ArithOp.DIV || a.op() == BoundExpr.ArithOp.MOD)
                && a.right() instanceof BoundExpr.Literal l && l.value() instanceof Long d) {
            return d == 0 || d == -1 && a.op() == BoundExpr.ArithOp.DIV; // x / c, x % c with a safe constant
        }
        return !a.type().isNull();
    }

    private static boolean castCanFail(DataType from, DataType to) {
        TypeKind f = from.kind();
        TypeKind t = to.kind();
        if (from.equals(to) || f == TypeKind.NULL || t == TypeKind.STRING) {
            return false;
        }
        return switch (f) {
            case INT64 -> t != TypeKind.FLOAT64 && t != TypeKind.BOOLEAN;
            case BOOLEAN -> t != TypeKind.INT64;
            case DECIMAL -> switch (t) {
                case FLOAT64, INT64 -> false;
                case DECIMAL -> !(to.scale() >= from.scale()
                        && to.precision() - to.scale() >= from.precision() - from.scale());
                default -> true;
            };
            case DATE -> t != TypeKind.TIMESTAMP;
            case TIMESTAMP -> t != TypeKind.DATE;
            default -> true;
        };
    }

    private static boolean anyCanFail(List<BoundExpr> exprs) {
        for (BoundExpr e : exprs) {
            if (canFail(e)) {
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------ predicate pushdown

    private static LogicalPlan pushdown(LogicalPlan plan) {
        return switch (plan) {
            case LogicalPlan.Scan s -> s;
            case LogicalPlan.SingleRow s -> s;
            case LogicalPlan.Filter f -> pushInto(pushdown(f.input()), BoundExprs.conjuncts(f.predicate()));
            case LogicalPlan.Join j -> pushInto(
                    new LogicalPlan.Join(pushdown(j.left()), pushdown(j.right()), j.kind(), j.condition()), List.of());
            case LogicalPlan.Aggregate a -> new LogicalPlan.Aggregate(pushdown(a.input()), a.groupKeys(),
                    a.aggregates());
            case LogicalPlan.Project p -> new LogicalPlan.Project(pushdown(p.input()), p.expressions(), p.names());
            case LogicalPlan.Distinct d -> new LogicalPlan.Distinct(pushdown(d.input()));
            case LogicalPlan.Sort s -> new LogicalPlan.Sort(pushdown(s.input()), s.keys());
            case LogicalPlan.Limit l -> new LogicalPlan.Limit(pushdown(l.input()), l.offset(), l.limit());
        };
    }

    private static boolean movable(BoundExpr e) {
        return !BoundExprs.containsCorrelatedSubquery(e);
    }

    /** Applies the conjunctive predicates to {@code node}, pushing them below it where possible. */
    private static LogicalPlan pushInto(LogicalPlan node, List<BoundExpr> preds) {
        if (node instanceof LogicalPlan.Filter f) {
            if (anyCanFail(preds)) {
                // merged, they would also be evaluated on rows the lower filter rejects (NULL)
                return filter(node, preds);
            }
            List<BoundExpr> all = new ArrayList<>(BoundExprs.conjuncts(f.predicate()));
            all.addAll(preds);
            return pushInto(f.input(), all);
        }
        if (!(node instanceof LogicalPlan.Join j)) {
            return filter(node, preds);
        }
        List<BoundExpr> condition = j.condition() == null ? List.of() : BoundExprs.conjuncts(j.condition());
        if (anyCanFail(preds)) {
            // Moving any predicate would change the rows the failing ones are evaluated on; the
            // join's own condition may still be pushed into its inputs (the join output is the same).
            return filter(preds.isEmpty() ? j : pushInto(j, List.of()), preds);
        }
        if (anyCanFail(condition)) {
            return j;
        }
        int leftWidth = j.left().schema().size();
        boolean left = j.kind() == LogicalPlan.JoinKind.LEFT;
        List<BoundExpr> toLeft = new ArrayList<>();
        List<BoundExpr> toRight = new ArrayList<>();
        List<BoundExpr> joinPreds = new ArrayList<>();
        List<BoundExpr> above = new ArrayList<>();

        // Conjuncts of the join condition itself.
        for (BoundExpr c : condition) {
            int[] range = BoundExprs.columnRange(c);
            if (!movable(c) || range[1] < 0) {
                joinPreds.add(c);
            } else if (range[0] >= leftWidth) {
                toRight.add(BoundExprs.shiftColumns(c, -leftWidth));
            } else if (range[1] < leftWidth && !left) {
                toLeft.add(c);
            } else {
                joinPreds.add(c);
            }
        }
        // Conjuncts of a filter above the join.
        for (BoundExpr c : preds) {
            int[] range = BoundExprs.columnRange(c);
            if (!movable(c) || range[1] < 0) {
                above.add(c);
            } else if (range[1] < leftWidth) {
                toLeft.add(c);
            } else if (range[0] >= leftWidth && !left) {
                toRight.add(BoundExprs.shiftColumns(c, -leftWidth));
            } else if (!left) {
                joinPreds.add(c);
            } else {
                above.add(c);
            }
        }
        LogicalPlan.JoinKind kind = j.kind();
        if (kind == LogicalPlan.JoinKind.CROSS && !joinPreds.isEmpty()) {
            kind = LogicalPlan.JoinKind.INNER;
        }
        BoundExpr cond = BoundExprs.and(joinPreds);
        if (kind == LogicalPlan.JoinKind.INNER && cond == null) {
            kind = LogicalPlan.JoinKind.CROSS;
        }
        LogicalPlan joined = new LogicalPlan.Join(pushInto(j.left(), toLeft), pushInto(j.right(), toRight), kind,
                kind == LogicalPlan.JoinKind.CROSS ? null : cond);
        return filter(joined, above);
    }

    private static LogicalPlan filter(LogicalPlan node, List<BoundExpr> preds) {
        BoundExpr p = BoundExprs.and(preds);
        return p == null ? node : new LogicalPlan.Filter(node, p);
    }
}
