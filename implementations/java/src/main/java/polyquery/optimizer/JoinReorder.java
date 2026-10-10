package polyquery.optimizer;

import java.util.ArrayList;
import java.util.BitSet;
import java.util.List;
import polyquery.physical.Cardinality;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.LogicalPlan;
import polyquery.storage.ColumnSchema;
import polyquery.storage.ColumnStats;
import polyquery.storage.Table;

/**
 * Join reordering for trees of inner (and cross) joins over three or more inputs: a greedy
 * order that starts with the smallest input and repeatedly adds the connected input giving the
 * smallest estimated intermediate result (equi-join estimates use distinct counts from table
 * statistics), building a left-deep tree; each join condition conjunct is placed at the
 * lowest join where all its inputs are available, and a projection on top restores the
 * original column order.
 *
 * <p>Applied only when every condition is free of subqueries and outer references and cannot
 * raise an error (a different order evaluates conditions on different row pairs). LEFT joins
 * and other operators are treated as opaque inputs (reordered inside separately).
 */
final class JoinReorder {
    private JoinReorder() {
    }

    /** An input of a join tree, at column {@code offset} of the tree's original layout. */
    private record Leaf(LogicalPlan plan, int offset, int width, double rows) {
    }

    /** A condition conjunct over the tree's original layout and the inputs it reads. */
    private record Pred(BoundExpr expr, BitSet leaves) {
    }

    static LogicalPlan reorder(LogicalPlan plan) {
        return switch (plan) {
            case LogicalPlan.Scan s -> s;
            case LogicalPlan.SingleRow s -> s;
            case LogicalPlan.Filter f -> new LogicalPlan.Filter(reorder(f.input()), f.predicate());
            case LogicalPlan.Join j when j.kind() != LogicalPlan.JoinKind.LEFT -> tree(j);
            case LogicalPlan.Join j -> new LogicalPlan.Join(reorder(j.left()), reorder(j.right()), j.kind(),
                    j.condition());
            case LogicalPlan.Aggregate a -> new LogicalPlan.Aggregate(reorder(a.input()), a.groupKeys(),
                    a.aggregates());
            case LogicalPlan.Project p -> new LogicalPlan.Project(reorder(p.input()), p.expressions(), p.names());
            case LogicalPlan.Distinct d -> new LogicalPlan.Distinct(reorder(d.input()));
            case LogicalPlan.Sort s -> new LogicalPlan.Sort(reorder(s.input()), s.keys());
            case LogicalPlan.Limit l -> new LogicalPlan.Limit(reorder(l.input()), l.offset(), l.limit());
        };
    }

    private static boolean innerOrCross(LogicalPlan p) {
        return p instanceof LogicalPlan.Join j && j.kind() != LogicalPlan.JoinKind.LEFT;
    }

    /** Collects the inputs and (shifted) condition conjuncts of a maximal inner-join tree. */
    private static void flatten(LogicalPlan node, int offset, List<LogicalPlan> inputs, List<Integer> offsets,
                                List<BoundExpr> conds) {
        if (innerOrCross(node)) {
            LogicalPlan.Join j = (LogicalPlan.Join) node;
            flatten(j.left(), offset, inputs, offsets, conds);
            flatten(j.right(), offset + j.left().schema().size(), inputs, offsets, conds);
            if (j.condition() != null) {
                for (BoundExpr c : BoundExprs.conjuncts(j.condition())) {
                    conds.add(BoundExprs.shiftColumns(c, offset));
                }
            }
            return;
        }
        inputs.add(node);
        offsets.add(offset);
    }

    /** Replaces the inputs of an inner-join tree (in order) without changing its shape. */
    private static LogicalPlan withInputs(LogicalPlan node, java.util.Iterator<LogicalPlan> inputs) {
        if (innerOrCross(node)) {
            LogicalPlan.Join j = (LogicalPlan.Join) node;
            LogicalPlan left = withInputs(j.left(), inputs);
            LogicalPlan right = withInputs(j.right(), inputs);
            return new LogicalPlan.Join(left, right, j.kind(), j.condition());
        }
        return inputs.next();
    }

    private static LogicalPlan tree(LogicalPlan.Join root) {
        List<LogicalPlan> inputs = new ArrayList<>();
        List<Integer> offsets = new ArrayList<>();
        List<BoundExpr> conds = new ArrayList<>();
        flatten(root, 0, inputs, offsets, conds);
        List<LogicalPlan> optimizedInputs = new ArrayList<>();
        for (LogicalPlan in : inputs) {
            optimizedInputs.add(reorder(in));
        }
        LogicalPlan unchanged = withInputs(root, optimizedInputs.iterator());
        if (inputs.size() < 3) {
            return unchanged;
        }
        for (BoundExpr c : conds) {
            if (BoundExprs.containsSubquery(c) || BoundExprs.any(c, x -> x instanceof BoundExpr.OuterRef)
                    || LogicalOptimizer.canFail(c)) {
                return unchanged;
            }
        }
        List<Leaf> leaves = new ArrayList<>();
        for (int i = 0; i < inputs.size(); i++) {
            LogicalPlan in = optimizedInputs.get(i);
            leaves.add(new Leaf(in, offsets.get(i), in.schema().size(), Math.max(1, Cardinality.rows(in))));
        }
        List<Pred> preds = new ArrayList<>();
        for (BoundExpr c : conds) {
            preds.add(new Pred(c, leavesOf(c, leaves)));
        }
        int[] order = greedyOrder(leaves, preds);
        boolean identity = true;
        for (int i = 0; i < order.length; i++) {
            identity &= order[i] == i;
        }
        if (identity) {
            return unchanged;
        }
        return rebuild(root, leaves, preds, order);
    }

    private static BitSet leavesOf(BoundExpr e, List<Leaf> leaves) {
        BitSet out = new BitSet();
        BoundExprs.any(e, x -> {
            if (x instanceof BoundExpr.ColumnRef c) {
                out.set(leafOf(c.index(), leaves));
            }
            return false;
        });
        return out;
    }

    private static int leafOf(int column, List<Leaf> leaves) {
        for (int i = leaves.size() - 1; i >= 0; i--) {
            if (column >= leaves.get(i).offset()) {
                return i;
            }
        }
        return 0;
    }

    /** Greedy join order: smallest input first, then the connected input with the smallest estimated result. */
    private static int[] greedyOrder(List<Leaf> leaves, List<Pred> preds) {
        int n = leaves.size();
        int[] order = new int[n];
        BitSet chosen = new BitSet();
        int first = 0;
        for (int i = 1; i < n; i++) {
            if (leaves.get(i).rows() < leaves.get(first).rows()) {
                first = i;
            }
        }
        order[0] = first;
        chosen.set(first);
        double current = leaves.get(first).rows();
        for (int k = 1; k < n; k++) {
            int best = -1;
            double bestRows = Double.MAX_VALUE;
            boolean bestConnected = false;
            for (int i = 0; i < n; i++) {
                if (chosen.get(i)) {
                    continue;
                }
                double estimate = current * leaves.get(i).rows();
                boolean connected = false;
                for (Pred p : preds) {
                    if (!p.leaves().get(i) || p.leaves().cardinality() < 2) {
                        continue;
                    }
                    BitSet others = (BitSet) p.leaves().clone();
                    others.clear(i);
                    BitSet missing = (BitSet) others.clone();
                    missing.andNot(chosen);
                    if (!missing.isEmpty()) {
                        continue; // needs an input not joined yet
                    }
                    connected = true;
                    estimate *= selectivity(p, leaves);
                }
                // prefer connected inputs (no cross products), then the smallest estimate
                if (best < 0 || connected && !bestConnected
                        || connected == bestConnected && estimate < bestRows) {
                    best = i;
                    bestRows = estimate;
                    bestConnected = connected;
                }
            }
            order[k] = best;
            chosen.set(best);
            current = Math.max(1, bestRows);
        }
        return order;
    }

    /** Selectivity of a join conjunct: 1/max(ndv) for column equalities with statistics, else 1/3. */
    private static double selectivity(Pred p, List<Leaf> leaves) {
        if (p.expr() instanceof BoundExpr.Comparison cmp && cmp.op() == BoundExpr.CompareOp.EQ
                && cmp.left() instanceof BoundExpr.ColumnRef a && cmp.right() instanceof BoundExpr.ColumnRef b) {
            double ndv = Math.max(distinct(a.index(), leaves), distinct(b.index(), leaves));
            if (ndv > 0) {
                return 1.0 / ndv;
            }
        }
        return 1.0 / 3;
    }

    /** Distinct values of a column of a scanned table input (0 if unknown). */
    private static double distinct(int column, List<Leaf> leaves) {
        Leaf leaf = leaves.get(leafOf(column, leaves));
        LogicalPlan p = leaf.plan();
        while (p instanceof LogicalPlan.Filter f) {
            p = f.input();
        }
        if (p instanceof LogicalPlan.Scan s) {
            Table t = s.table();
            int c = column - leaf.offset();
            if (t.rowCount() == 0 || c >= t.columnCount()) {
                return 0;
            }
            ColumnStats stats = t.stats().column(c);
            return Math.min(stats.distinctCount(), leaf.rows());
        }
        return 0;
    }

    private static LogicalPlan rebuild(LogicalPlan.Join root, List<Leaf> leaves, List<Pred> preds, int[] order) {
        int width = root.schema().size();
        int[] newIndex = new int[width];
        int offset = 0;
        for (int i : order) {
            Leaf leaf = leaves.get(i);
            for (int c = 0; c < leaf.width(); c++) {
                newIndex[leaf.offset() + c] = offset + c;
            }
            offset += leaf.width();
        }
        boolean[] placed = new boolean[preds.size()];
        BitSet available = new BitSet();
        available.set(order[0]);
        LogicalPlan tree = leaves.get(order[0]).plan();
        for (int k = 1; k < order.length; k++) {
            available.set(order[k]);
            List<BoundExpr> here = new ArrayList<>();
            for (int p = 0; p < preds.size(); p++) {
                BitSet needs = (BitSet) preds.get(p).leaves().clone();
                needs.andNot(available);
                if (!placed[p] && needs.isEmpty()) {
                    placed[p] = true;
                    here.add(BoundExprs.rewrite(preds.get(p).expr(), x -> x instanceof BoundExpr.ColumnRef c
                            ? new BoundExpr.ColumnRef(newIndex[c.index()], c.type(), c.name()) : null));
                }
            }
            BoundExpr cond = BoundExprs.and(here);
            tree = new LogicalPlan.Join(tree, leaves.get(order[k]).plan(),
                    cond == null ? LogicalPlan.JoinKind.CROSS : LogicalPlan.JoinKind.INNER, cond);
        }
        List<ColumnSchema> schema = root.schema();
        List<BoundExpr> restore = new ArrayList<>(width);
        List<String> names = new ArrayList<>(width);
        for (int i = 0; i < width; i++) {
            restore.add(new BoundExpr.ColumnRef(newIndex[i], schema.get(i).type(), schema.get(i).name()));
            names.add(schema.get(i).name());
        }
        return new LogicalPlan.Project(tree, restore, names);
    }
}
