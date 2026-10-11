package polyquery.physical;

import java.util.ArrayList;
import java.util.BitSet;
import java.util.List;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.SortKey;

/**
 * Column pruning (indexes-and-planning.md §3), the last physical planning step: determines,
 * top-down, which input slots every operator actually reads and restricts each scan to the
 * columns referenced anywhere above it; projected column references and constants nobody reads
 * are not computed (as the logical {@code ProjectionPruning} rule does, so that
 * {@code optimize: false} reads the same columns). Row layouts are unchanged (pruned slots are
 * simply left null), so no expression needs to be rewritten.
 */
final class ColumnPruner {
    private ColumnPruner() {
    }

    /** Prunes a plan whose output rows are fully consumed. */
    static PhysicalPlan prune(PhysicalPlan plan) {
        BitSet all = new BitSet();
        all.set(0, plan.schema().size());
        return prune(plan, all);
    }

    /** @param required output slots of {@code plan} read by its consumer */
    private static PhysicalPlan prune(PhysicalPlan plan, BitSet required) {
        return switch (plan) {
            case PhysicalPlan.TableScan s -> s.withColumns(slots(required, s.schema().size()));
            case PhysicalPlan.IndexScan s -> s.withColumns(slots(required, s.schema().size()));
            case PhysicalPlan.Values v -> v;
            case PhysicalPlan.Filter f -> new PhysicalPlan.Filter(prune(f.input(), union(required, f.predicate())),
                    f.predicate());
            case PhysicalPlan.HashLookupFilter h -> {
                BitSet need = (BitSet) required.clone();
                for (BoundExpr e : h.expressions()) {
                    BoundExprs.addInputSlots(e, need);
                }
                yield new PhysicalPlan.HashLookupFilter(prune(h.input(), need), h.innerKeys(), h.outerKeys(),
                        h.staticPredicate(), h.dynamicPredicate());
            }
            case PhysicalPlan.Project p -> {
                // Outputs nobody reads are not computed if computing them cannot fail (a plain
                // column or literal); their slots become NULL so the columns need not be read.
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
                yield new PhysicalPlan.Project(prune(p.input(), need), exprs, p.names());
            }
            case PhysicalPlan.HashAggregate a -> {
                BitSet need = new BitSet();
                for (BoundExpr e : a.groupKeys()) {
                    BoundExprs.addInputSlots(e, need);
                }
                for (AggregateCall c : a.aggregates()) {
                    if (c.argument() != null) {
                        BoundExprs.addInputSlots(c.argument(), need);
                    }
                }
                yield new PhysicalPlan.HashAggregate(prune(a.input(), need), a.groupKeys(), a.aggregates());
            }
            case PhysicalPlan.HashDistinct d -> {
                BitSet need = new BitSet();
                need.set(0, d.input().schema().size());
                yield new PhysicalPlan.HashDistinct(prune(d.input(), need));
            }
            case PhysicalPlan.Sort s -> {
                BitSet need = (BitSet) required.clone();
                for (SortKey k : s.keys()) {
                    need.set(k.column());
                }
                yield new PhysicalPlan.Sort(prune(s.input(), need), s.keys());
            }
            case PhysicalPlan.TopN t -> {
                BitSet need = (BitSet) required.clone();
                for (SortKey k : t.keys()) {
                    need.set(k.column());
                }
                yield new PhysicalPlan.TopN(prune(t.input(), need), t.keys(), t.offset(), t.limit());
            }
            case PhysicalPlan.Limit l -> new PhysicalPlan.Limit(prune(l.input(), required), l.offset(), l.limit());
            // Every branch fills the same output slots.
            case PhysicalPlan.UnionAll u -> new PhysicalPlan.UnionAll(
                    u.inputs().stream().map(in -> prune(in, required)).toList(), u.columns());
            case PhysicalPlan.MergeJoin j -> {
                int leftWidth = j.left().schema().size();
                BitSet need = j.residual() == null ? required : union(required, j.residual());
                BitSet left = need.get(0, leftWidth);
                BitSet right = shifted(need, leftWidth);
                j.leftKeys().forEach(e -> BoundExprs.addInputSlots(e, left));
                j.rightKeys().forEach(e -> BoundExprs.addInputSlots(e, right));
                yield new PhysicalPlan.MergeJoin(prune(j.left(), left), prune(j.right(), right), j.kind(),
                        j.leftKeys(), j.rightKeys(), j.residual());
            }
            case PhysicalPlan.HashJoin j -> {
                int leftWidth = j.left().schema().size();
                BitSet need = j.residual() == null ? required : union(required, j.residual());
                BitSet left = need.get(0, leftWidth);
                BitSet right = shifted(need, leftWidth);
                j.leftKeys().forEach(e -> BoundExprs.addInputSlots(e, left));
                j.rightKeys().forEach(e -> BoundExprs.addInputSlots(e, right));
                yield new PhysicalPlan.HashJoin(prune(j.left(), left), prune(j.right(), right), j.kind(), j.leftKeys(),
                        j.rightKeys(), j.residual(), j.buildLeft());
            }
            case PhysicalPlan.NestedLoopJoin j -> {
                int leftWidth = j.left().schema().size();
                BitSet need = j.condition() == null ? required : union(required, j.condition());
                yield new PhysicalPlan.NestedLoopJoin(prune(j.left(), need.get(0, leftWidth)),
                        prune(j.right(), shifted(need, leftWidth)), j.kind(), j.condition());
            }
        };
    }

    private static BitSet union(BitSet required, BoundExpr e) {
        BitSet out = (BitSet) required.clone();
        BoundExprs.addInputSlots(e, out);
        return out;
    }

    private static BitSet shifted(BitSet set, int offset) {
        BitSet out = new BitSet();
        for (int i = set.nextSetBit(offset); i >= 0; i = set.nextSetBit(i + 1)) {
            out.set(i - offset);
        }
        return out;
    }

    private static int[] slots(BitSet required, int width) {
        return required.get(0, width).stream().toArray();
    }
}
