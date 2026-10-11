package polyquery.optimizer;

import java.util.ArrayList;
import java.util.BitSet;
import java.util.List;
import polyquery.cost.Cardinality;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.plan.LogicalPlan;
import polyquery.storage.ColumnSchema;
import polyquery.storage.ColumnStats;
import polyquery.storage.Table;

/**
 * Join reordering for trees of inner (and cross) joins over three or more inputs: a greedy
 * order that starts with the connected pair of inputs with the smallest estimated join result
 * and repeatedly adds the connected input giving the smallest estimated intermediate result
 * (equi-join estimates use distinct counts from table statistics), building a left-deep tree; each join condition conjunct is placed at the
 * lowest join where all its inputs are available, and a projection on top restores the
 * original column order.
 *
 * <p>Applied only when every condition is free of subqueries and outer references and cannot
 * raise an error (a different order evaluates conditions on different row pairs). LEFT joins
 * and other operators are treated as opaque inputs (reordered inside separately).
 */
public final class JoinReorder implements OptimizerRule {
    /** An input of a join tree, at column {@code offset} of the tree's original layout. */
    private record Leaf(LogicalPlan plan, int offset, int width, double rows) {
    }

    /** A condition conjunct over the tree's original layout and the inputs it reads. */
    private record Pred(BoundExpr expr, BitSet leaves) {
    }

    @Override
    public String name() {
        return "join_reordering";
    }

    /** Top-down, so that each maximal inner-join tree is reordered as a whole. */
    @Override
    public LogicalPlan apply(LogicalPlan plan) {
        if (innerOrCross(plan)) {
            return tree((LogicalPlan.Join) plan);
        }
        return plan.withChildren(plan.children().stream().map(this::apply).toList());
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

    private LogicalPlan tree(LogicalPlan.Join root) {
        List<LogicalPlan> inputs = new ArrayList<>();
        List<Integer> offsets = new ArrayList<>();
        List<BoundExpr> conds = new ArrayList<>();
        flatten(root, 0, inputs, offsets, conds);
        List<LogicalPlan> optimizedInputs = new ArrayList<>();
        for (LogicalPlan in : inputs) {
            optimizedInputs.add(apply(in));
        }
        LogicalPlan unchanged = withInputs(root, optimizedInputs.iterator());
        if (inputs.size() < 3) {
            return unchanged;
        }
        ExprSafety safety = new ExprSafety(ExprSafety.origins(root));
        for (BoundExpr c : conds) {
            if (BoundExprs.containsSubquery(c) || BoundExprs.any(c, x -> x instanceof BoundExpr.OuterRef)
                    || safety.canFail(c)) {
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

    /** Estimated rows of joining a result of {@code rows} rows over inputs {@code have} with input {@code next}. */
    private static double joinRows(double rows, BitSet have, int next, List<Leaf> leaves, List<Pred> preds) {
        double estimate = rows * leaves.get(next).rows();
        for (Pred p : preds) {
            if (!p.leaves().get(next) || p.leaves().cardinality() < 2) {
                continue;
            }
            BitSet missing = (BitSet) p.leaves().clone();
            missing.clear(next);
            missing.andNot(have);
            if (missing.isEmpty()) {
                estimate *= selectivity(p, leaves);
            }
        }
        return estimate;
    }

    /** True if some conjunct joins input {@code next} with inputs in {@code have} only. */
    private static boolean connected(BitSet have, int next, List<Pred> preds) {
        for (Pred p : preds) {
            if (!p.leaves().get(next) || p.leaves().cardinality() < 2) {
                continue;
            }
            BitSet others = (BitSet) p.leaves().clone();
            others.clear(next);
            BitSet missing = (BitSet) others.clone();
            missing.andNot(have);
            if (missing.isEmpty() && !others.isEmpty()) {
                return true;
            }
        }
        return false;
    }

    /**
     * Greedy join order: the connected pair of inputs with the smallest estimated join result
     * first, then repeatedly the connected input giving the smallest estimated result (cross
     * products only when nothing is connected; ties keep the original order).
     */
    private static int[] greedyOrder(List<Leaf> leaves, List<Pred> preds) {
        int n = leaves.size();
        int[] order = new int[n];
        BitSet chosen = new BitSet();
        int bestA = -1;
        int bestB = -1;
        double bestRows = Double.MAX_VALUE;
        for (int a = 0; a < n; a++) {
            BitSet have = new BitSet();
            have.set(a);
            for (int b = a + 1; b < n; b++) {
                if (!connected(have, b, preds)) {
                    continue;
                }
                double rows = joinRows(leaves.get(a).rows(), have, b, leaves, preds);
                if (rows < bestRows) {
                    bestRows = rows;
                    bestA = a;
                    bestB = b;
                }
            }
        }
        if (bestA < 0) {
            for (int i = 0; i < n; i++) {
                order[i] = i; // no join predicates at all: keep the written order
            }
            return order;
        }
        order[0] = bestA;
        order[1] = bestB;
        chosen.set(bestA);
        chosen.set(bestB);
        double current = Math.max(1, bestRows);
        for (int k = 2; k < n; k++) {
            int best = -1;
            double bestEstimate = Double.MAX_VALUE;
            boolean bestConnected = false;
            for (int i = 0; i < n; i++) {
                if (chosen.get(i)) {
                    continue;
                }
                boolean isConnected = connected(chosen, i, preds);
                double estimate = joinRows(current, chosen, i, leaves, preds);
                if (best < 0 || isConnected && !bestConnected
                        || isConnected == bestConnected && estimate < bestEstimate) {
                    best = i;
                    bestEstimate = estimate;
                    bestConnected = isConnected;
                }
            }
            order[k] = best;
            chosen.set(best);
            current = Math.max(1, bestEstimate);
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
