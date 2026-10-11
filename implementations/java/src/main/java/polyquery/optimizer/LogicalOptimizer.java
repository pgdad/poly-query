package polyquery.optimizer;

import java.util.ArrayList;
import java.util.List;
import polyquery.common.PolyQueryException;
import polyquery.exec.ConstantEvaluator;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.LogicalPlan;

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
 * <p>Every rewrite preserves results <em>and errors</em>. Moving a predicate changes the rows
 * the others are evaluated on, so conjuncts move only if they precede every conjunct that may
 * raise an error — and, when such a conjunct exists, only if they can never be NULL (both
 * decided by {@link ExprSafety}, with column statistics). Predicates containing correlated
 * subqueries are never moved: their correlation frame is the row layout of the operator they
 * were bound against.
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
            case LogicalPlan.UnionAll u -> u.withInputs(u.inputs().stream().map(LogicalOptimizer::fold).toList());
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

    /**
     * Conservative: false only if evaluating {@code e} can never raise an error (overflow,
     * division by zero, conversion, subquery cardinality, …) on any row. Without statistics;
     * see {@link ExprSafety} for the statistics-aware analysis used by predicate pushdown.
     */
    public static boolean canFail(BoundExpr e) {
        return new ExprSafety(null).canFail(e);
    }

    /** Index of the first conjunct that may fail, or {@code preds.size()}. */
    private static int firstFailing(List<BoundExpr> preds, ExprSafety safety) {
        for (int i = 0; i < preds.size(); i++) {
            if (safety.canFail(preds.get(i))) {
                return i;
            }
        }
        return preds.size();
    }

    /**
     * Conjuncts that may be evaluated earlier, on fewer or other rows, without changing results
     * or errors: those before the first conjunct that may fail — and, if one may fail, only
     * conjuncts that are never NULL (a NULL conjunct does not stop the evaluation of the
     * following ones, a pushed-down filter would).
     */
    private static boolean[] movableConjuncts(List<BoundExpr> preds, ExprSafety safety) {
        int fail = firstFailing(preds, safety);
        boolean[] out = new boolean[preds.size()];
        for (int i = 0; i < fail; i++) {
            out[i] = !BoundExprs.containsCorrelatedSubquery(preds.get(i))
                    && (fail == preds.size() || safety.neverNull(preds.get(i)));
        }
        return out;
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
            case LogicalPlan.UnionAll u -> u.withInputs(u.inputs().stream().map(LogicalOptimizer::pushdown).toList());
            case LogicalPlan.Sort s -> new LogicalPlan.Sort(pushdown(s.input()), s.keys());
            case LogicalPlan.Limit l -> new LogicalPlan.Limit(pushdown(l.input()), l.offset(), l.limit());
        };
    }

    /** Applies the conjunctive predicates to {@code node}, pushing them below it where possible. */
    private static LogicalPlan pushInto(LogicalPlan node, List<BoundExpr> preds) {
        if (node instanceof LogicalPlan.Filter f) {
            // Merged into one conjunction, the outer predicates would also be evaluated on rows
            // where the inner one is NULL: only if that cannot raise an error.
            List<BoundExpr> inner = BoundExprs.conjuncts(f.predicate());
            ExprSafety safety = new ExprSafety(ExprSafety.origins(f.input()));
            if (firstFailing(preds, safety) < preds.size() && !inner.stream().allMatch(safety::neverNull)) {
                return filter(node, preds);
            }
            List<BoundExpr> all = new ArrayList<>(inner);
            all.addAll(preds);
            return pushInto(f.input(), all);
        }
        if (!(node instanceof LogicalPlan.Join j)) {
            return filter(node, preds);
        }
        ExprSafety safety = new ExprSafety(ExprSafety.origins(j));
        List<BoundExpr> condition = j.condition() == null ? List.of() : BoundExprs.conjuncts(j.condition());
        boolean[] condMovable = movableConjuncts(condition, safety);
        boolean conditionCanFail = firstFailing(condition, safety) < condition.size();
        // A join condition that may fail must keep seeing the same row pairs: then nothing from
        // above may move into or below the join.
        boolean[] predMovable = conditionCanFail ? new boolean[preds.size()] : movableConjuncts(preds, safety);

        int leftWidth = j.left().schema().size();
        boolean left = j.kind() == LogicalPlan.JoinKind.LEFT;
        List<BoundExpr> toLeft = new ArrayList<>();
        List<BoundExpr> toRight = new ArrayList<>();
        List<BoundExpr> joinPreds = new ArrayList<>();
        List<BoundExpr> above = new ArrayList<>();

        // Conjuncts of the join condition itself.
        for (int i = 0; i < condition.size(); i++) {
            BoundExpr c = condition.get(i);
            int[] range = BoundExprs.columnRange(c);
            if (!condMovable[i] || range[1] < 0) {
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
        for (int i = 0; i < preds.size(); i++) {
            BoundExpr c = preds.get(i);
            int[] range = BoundExprs.columnRange(c);
            if (!predMovable[i] || range[1] < 0) {
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
