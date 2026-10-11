package polyquery.optimizer;

import java.util.ArrayList;
import java.util.BitSet;
import java.util.List;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.LogicalPlan;
import polyquery.plan.SortKey;

/**
 * Projection (column) pruning: determines, top-down, which output columns of every operator
 * are read above it, and replaces projected column references and constants nobody reads —
 * typically columns of a derived table or CTE the outer query ignores — by NULL constants, so
 * the columns they pass through are no longer needed below. Row layouts are unchanged, so no
 * expression needs to be rewritten. Computed expressions are always kept: evaluating them may
 * raise an error the query has to report.
 *
 * <p>Physical planning restricts every scan to the columns its plan reads with the same
 * pass-through criterion (Phase 3 column pruning), so scans read the same columns with and
 * without the optimizer.
 */
public final class ProjectionPruning implements OptimizerRule {
    @Override
    public String name() {
        return "projection_pruning";
    }

    @Override
    public LogicalPlan apply(LogicalPlan plan) {
        BitSet all = new BitSet();
        all.set(0, plan.schema().size());
        return prune(plan, all);
    }

    /** @param required output columns of {@code plan} read by its consumer */
    private static LogicalPlan prune(LogicalPlan plan, BitSet required) {
        return switch (plan) {
            case LogicalPlan.Scan s -> s;
            case LogicalPlan.SingleRow s -> s;
            case LogicalPlan.Filter f -> new LogicalPlan.Filter(prune(f.input(), with(required, f.predicate())),
                    f.predicate());
            case LogicalPlan.Project p -> {
                BitSet need = new BitSet();
                List<BoundExpr> exprs = new ArrayList<>(p.expressions());
                for (int i = 0; i < exprs.size(); i++) {
                    BoundExpr e = exprs.get(i);
                    if (!required.get(i) && (e instanceof BoundExpr.ColumnRef || e instanceof BoundExpr.Literal)) {
                        exprs.set(i, new BoundExpr.Literal(null, e.type()));
                    } else {
                        BoundExprs.addInputSlots(e, need);
                    }
                }
                yield new LogicalPlan.Project(prune(p.input(), need), exprs, p.names());
            }
            case LogicalPlan.Aggregate a -> {
                BitSet need = new BitSet();
                a.groupKeys().forEach(e -> BoundExprs.addInputSlots(e, need));
                for (AggregateCall c : a.aggregates()) {
                    if (c.argument() != null) {
                        BoundExprs.addInputSlots(c.argument(), need);
                    }
                }
                yield new LogicalPlan.Aggregate(prune(a.input(), need), a.groupKeys(), a.aggregates());
            }
            case LogicalPlan.Distinct d -> {
                BitSet all = new BitSet();
                all.set(0, d.input().schema().size());
                yield new LogicalPlan.Distinct(prune(d.input(), all));
            }
            case LogicalPlan.Sort s -> {
                BitSet need = (BitSet) required.clone();
                for (SortKey k : s.keys()) {
                    need.set(k.column());
                }
                yield new LogicalPlan.Sort(prune(s.input(), need), s.keys());
            }
            case LogicalPlan.Limit l -> new LogicalPlan.Limit(prune(l.input(), required), l.offset(), l.limit());
            // Every branch fills the same output columns.
            case LogicalPlan.UnionAll u -> u.withChildren(u.inputs().stream().map(in -> prune(in, required)).toList());
            case LogicalPlan.Join j -> {
                int leftWidth = j.left().schema().size();
                BitSet need = j.condition() == null ? required : with(required, j.condition());
                BitSet right = new BitSet();
                for (int i = need.nextSetBit(leftWidth); i >= 0; i = need.nextSetBit(i + 1)) {
                    right.set(i - leftWidth);
                }
                yield new LogicalPlan.Join(prune(j.left(), need.get(0, leftWidth)), prune(j.right(), right), j.kind(),
                        j.condition());
            }
        };
    }

    private static BitSet with(BitSet required, BoundExpr e) {
        BitSet out = (BitSet) required.clone();
        BoundExprs.addInputSlots(e, out);
        return out;
    }
}
