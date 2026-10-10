package polyquery.physical;

import java.util.BitSet;
import java.util.List;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.SortKey;
import polyquery.plan.Subquery;

/**
 * Column pruning (indexes-and-planning.md §3): determines, top-down, which input slots every
 * operator actually reads and restricts each scan to the columns referenced anywhere above it.
 * Row layouts are unchanged (pruned slots are simply left null), so no expression needs to
 * be rewritten.
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
                    addReferences(e, need);
                }
                yield new PhysicalPlan.HashLookupFilter(prune(h.input(), need), h.innerKeys(), h.outerKeys(),
                        h.staticPredicate(), h.dynamicPredicate());
            }
            case PhysicalPlan.Project p -> {
                BitSet need = new BitSet();
                for (BoundExpr e : p.expressions()) {
                    addReferences(e, need);
                }
                yield new PhysicalPlan.Project(prune(p.input(), need), p.expressions(), p.names());
            }
            case PhysicalPlan.HashAggregate a -> {
                BitSet need = new BitSet();
                for (BoundExpr e : a.groupKeys()) {
                    addReferences(e, need);
                }
                for (AggregateCall c : a.aggregates()) {
                    if (c.argument() != null) {
                        addReferences(c.argument(), need);
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
            case PhysicalPlan.Limit l -> new PhysicalPlan.Limit(prune(l.input(), required), l.offset(), l.limit());
            case PhysicalPlan.HashJoin j -> {
                int leftWidth = j.left().schema().size();
                BitSet need = j.residual() == null ? required : union(required, j.residual());
                BitSet left = need.get(0, leftWidth);
                BitSet right = shifted(need, leftWidth);
                j.leftKeys().forEach(e -> addReferences(e, left));
                j.rightKeys().forEach(e -> addReferences(e, right));
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
        addReferences(e, out);
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

    /**
     * Adds the input slots an expression reads: its column references plus, for correlated
     * subqueries evaluated on this row, the slots their outer references point to.
     */
    static void addReferences(BoundExpr e, BitSet out) {
        BoundExprs.any(e, x -> {
            if (x instanceof BoundExpr.ColumnRef c) {
                out.set(c.index());
            } else if (x instanceof BoundExpr.AggregateRef a) {
                out.set(a.index());
            } else {
                Subquery sub = BoundExprs.subqueryOf(x);
                if (sub != null) {
                    addFrameReferences(sub, out);
                }
            }
            return false;
        });
    }

    private static void addFrameReferences(Subquery sub, BitSet out) {
        int[] map = sub.frameMap();
        List<BoundExpr.OuterRef> refs = sub.outerRefs();
        for (BoundExpr.OuterRef r : refs) {
            if (r.frame() != sub.frame()) {
                continue;
            }
            if (map == null) {
                out.set(r.index());
            } else if (r.index() < map.length && map[r.index()] >= 0) {
                out.set(map[r.index()]);
            }
        }
    }
}
