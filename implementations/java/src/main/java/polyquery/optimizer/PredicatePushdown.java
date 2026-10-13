package polyquery.optimizer;

import java.util.ArrayList;
import java.util.List;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.LogicalPlan;

/**
 * Predicate pushdown: WHERE conjuncts and join conditions are moved as close to the scans as
 * semantics allow — below projections (column references replaced by the projected
 * expressions), into join inputs (not into the null-supplying side of a LEFT join) and into
 * the filter directly above a scan, where physical planning can use them for index lookups
 * and row-group skipping. Cross joins that receive a join predicate become inner joins.
 *
 * <p>Error-preserving: only conjuncts that precede every conjunct that may fail move (and,
 * when one may fail, only conjuncts that are never NULL); nothing moves across a join
 * condition that may fail, or below a projection that may fail.
 */
public final class PredicatePushdown implements OptimizerRule {
    @Override
    public String name() {
        return "predicate_pushdown";
    }

    @Override
    public LogicalPlan apply(LogicalPlan plan) {
        Pass pass = new Pass();
        return plan.transformUp(node -> switch (node) {
            case LogicalPlan.Filter f -> pass.pushInto(f.input(), BoundExprs.conjuncts(f.predicate()));
            case LogicalPlan.Join j -> pass.pushInto(j, List.of());
            default -> node;
        });
    }

    /** One application of the rule (origins are memoized per pass). */
    private static final class Pass {
        private final ExprSafety.OriginCache origins = new ExprSafety.OriginCache();

        /** Index of the first conjunct that may fail, or {@code preds.size()}. */
        private int firstFailing(List<BoundExpr> preds, ExprSafety safety) {
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
        private boolean[] movableConjuncts(List<BoundExpr> preds, ExprSafety safety) {
            int fail = firstFailing(preds, safety);
            boolean[] out = new boolean[preds.size()];
            for (int i = 0; i < fail; i++) {
                out[i] = !BoundExprs.containsCorrelatedSubquery(preds.get(i))
                        && (fail == preds.size() || safety.neverNull(preds.get(i)));
            }
            return out;
        }

        /** Applies the conjunctive predicates to {@code node}, pushing them below it where possible. */
        private LogicalPlan pushInto(LogicalPlan node, List<BoundExpr> preds) {
            return switch (node) {
                case LogicalPlan.Filter f -> pushIntoFilter(f, preds);
                case LogicalPlan.Project p -> pushBelowProject(p, preds);
                case LogicalPlan.Join j -> pushIntoJoin(j, preds);
                default -> filter(node, preds);
            };
        }

        private LogicalPlan pushIntoFilter(LogicalPlan.Filter f, List<BoundExpr> preds) {
            // Merged into one conjunction, the outer predicates would also be evaluated on rows
            // where the inner one is NULL: only if that cannot raise an error.
            List<BoundExpr> inner = BoundExprs.conjuncts(f.predicate());
            ExprSafety safety = new ExprSafety(origins.of(f.input()));
            if (firstFailing(preds, safety) < preds.size() && !inner.stream().allMatch(safety::neverNull)) {
                return filter(f, preds);
            }
            List<BoundExpr> all = new ArrayList<>(inner);
            all.addAll(preds);
            return pushInto(f.input(), all);
        }

        /**
         * Moves conjuncts below a projection, rewritten over its input. The projection is then
         * computed on fewer rows, so it must not be able to fail (subqueries always may).
         */
        private LogicalPlan pushBelowProject(LogicalPlan.Project p, List<BoundExpr> preds) {
            ExprSafety inputSafety = new ExprSafety(origins.of(p.input()));
            if (preds.isEmpty() || p.expressions().stream().anyMatch(inputSafety::canFail)) {
                return filter(p, preds);
            }
            boolean[] movable = movableConjuncts(preds, new ExprSafety(origins.of(p)));
            List<BoundExpr> below = new ArrayList<>();
            List<BoundExpr> above = new ArrayList<>();
            for (int i = 0; i < preds.size(); i++) {
                if (movable[i]) {
                    below.add(BoundExprs.rewrite(preds.get(i),
                            x -> x instanceof BoundExpr.ColumnRef c ? p.expressions().get(c.index()) : null));
                } else {
                    above.add(preds.get(i));
                }
            }
            if (below.isEmpty()) {
                return filter(p, preds);
            }
            return filter(new LogicalPlan.Project(pushInto(p.input(), below), p.expressions(), p.names()), above);
        }

        private LogicalPlan pushIntoJoin(LogicalPlan.Join j, List<BoundExpr> preds) {
            ExprSafety safety = new ExprSafety(origins.of(j));
            List<BoundExpr> condition = j.condition() == null ? List.of() : BoundExprs.conjuncts(j.condition());
            boolean[] condMovable = movableConjuncts(condition, safety);
            boolean conditionCanFail = firstFailing(condition, safety) < condition.size();
            // A join condition that may fail must keep seeing the same row pairs: then nothing from
            // above may move into or below the join.
            boolean[] predMovable = conditionCanFail ? new boolean[preds.size()] : movableConjuncts(preds, safety);

            int leftWidth = origins.of(j.left()).length; // memoized: join trees can be deep
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

        private LogicalPlan filter(LogicalPlan node, List<BoundExpr> preds) {
            BoundExpr p = BoundExprs.and(preds);
            return p == null ? node : new LogicalPlan.Filter(node, p);
        }
    }
}
