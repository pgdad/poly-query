package polyquery.exec;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.UnaryOperator;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;

/** Join operators (semantics.md §7). Output rows are the left columns followed by the right columns. */
public final class JoinOperators {
    private JoinOperators() {
    }

    /** Shared probe-side logic: iterates left rows, candidate right rows, and LEFT JOIN padding. */
    private abstract static class JoinBase implements Operator {
        private final Operator left;
        final Operator right;
        private final Evaluator condition;
        private final boolean leftOuter;
        private final int rightWidth;
        final ExecContext ctx;
        private long produced;
        long reserved;
        private Object[] leftRow;
        private List<Object[]> candidates;
        private int next;
        private boolean matched;

        JoinBase(Operator left, Operator right, Evaluator condition, boolean leftOuter, int rightWidth,
                 ExecContext ctx) {
            this.left = left;
            this.right = right;
            this.condition = condition;
            this.leftOuter = leftOuter;
            this.rightWidth = rightWidth;
            this.ctx = ctx;
        }

        /** Materializes the right input (called from {@link #open()}). */
        abstract void build();

        /** Right rows that may match {@code leftRow}. */
        abstract List<Object[]> candidates(Object[] leftRow);

        @Override
        public void open() {
            produced = 0;
            leftRow = null;
            candidates = null;
            right.open();
            build();
            left.open();
        }

        @Override
        public Object[] next() {
            while (true) {
                if (candidates != null) {
                    while (next < candidates.size()) {
                        Object[] r = candidates.get(next++);
                        Object[] combined = concat(leftRow, r);
                        ctx.checkpoint();
                        if (condition == null || Boolean.TRUE.equals(condition.eval(combined))) {
                            matched = true;
                            return emit(combined);
                        }
                    }
                    candidates = null;
                    if (leftOuter && !matched) {
                        return emit(concat(leftRow, new Object[rightWidth]));
                    }
                }
                leftRow = left.next();
                if (leftRow == null) {
                    return null;
                }
                candidates = candidates(leftRow);
                next = 0;
                matched = false;
            }
        }

        private Object[] emit(Object[] row) {
            if (++produced > ctx.maxJoinRows()) {
                throw new PolyQueryException(ErrorCode.RESOURCE_LIMIT,
                        "join produced more than " + ctx.maxJoinRows() + " rows");
            }
            return row;
        }

        static Object[] concat(Object[] a, Object[] b) {
            Object[] out = new Object[a.length + b.length];
            System.arraycopy(a, 0, out, 0, a.length);
            System.arraycopy(b, 0, out, a.length, b.length);
            return out;
        }

        @Override
        public void close() {
            left.close();
            right.close();
            ctx.release(reserved);
            reserved = 0;
            candidates = null;
        }
    }

    /** Evaluates the condition for every pair; the right input is materialized once per open. */
    public static final class NestedLoopJoin extends JoinBase {
        private List<Object[]> rows;

        public NestedLoopJoin(Operator left, Operator right, Evaluator condition, boolean leftOuter, int rightWidth,
                              ExecContext ctx) {
            super(left, right, condition, leftOuter, rightWidth, ctx);
        }

        @Override
        void build() {
            rows = new ArrayList<>();
            Object[] r;
            while ((r = right.next()) != null) {
                long size = ExecContext.estimateRow(r);
                ctx.reserve(size);
                reserved += size;
                rows.add(r);
                ctx.checkpoint();
            }
        }

        @Override
        List<Object[]> candidates(Object[] leftRow) {
            return rows;
        }
    }

    /** Equi-join: hash table on the right input; NULL keys never match. */
    public static final class HashJoin extends JoinBase {
        private final Evaluator[] leftKeys;
        private final Evaluator[] rightKeys;
        private final List<UnaryOperator<Object>> leftNorm;
        private final List<UnaryOperator<Object>> rightNorm;
        private Map<Object, List<Object[]>> table;

        /**
         * @param residual  extra condition over combined rows (may be null)
         * @param leftNorm  per key: canonicalization of left key values (see {@link HashKeys})
         * @param rightNorm per key: canonicalization of right key values
         */
        public HashJoin(Operator left, Operator right, Evaluator[] leftKeys, Evaluator[] rightKeys,
                        List<UnaryOperator<Object>> leftNorm, List<UnaryOperator<Object>> rightNorm, Evaluator residual,
                        boolean leftOuter, int rightWidth, ExecContext ctx) {
            super(left, right, residual, leftOuter, rightWidth, ctx);
            this.leftKeys = leftKeys;
            this.rightKeys = rightKeys;
            this.leftNorm = leftNorm;
            this.rightNorm = rightNorm;
        }

        static Object key(Object[] row, Evaluator[] keys, List<UnaryOperator<Object>> norm) {
            if (keys.length == 1) {
                Object v = keys[0].eval(row);
                return v == null ? null : norm.get(0).apply(v);
            }
            Object[] k = new Object[keys.length];
            for (int i = 0; i < k.length; i++) {
                Object v = keys[i].eval(row);
                if (v == null) {
                    return null;
                }
                k[i] = norm.get(i).apply(v);
            }
            return new HashKeys.RowKey(k);
        }

        @Override
        void build() {
            table = new HashMap<>();
            Object[] r;
            while ((r = right.next()) != null) {
                ctx.checkpoint();
                Object k = key(r, rightKeys, rightNorm);
                if (k == null) {
                    continue;
                }
                long size = ExecContext.estimateRow(r) + 32;
                ctx.reserve(size);
                reserved += size;
                table.computeIfAbsent(k, x -> new ArrayList<>(2)).add(r);
            }
        }

        @Override
        List<Object[]> candidates(Object[] leftRow) {
            Object k = key(leftRow, leftKeys, leftNorm);
            return k == null ? List.of() : table.getOrDefault(k, List.of());
        }

        @Override
        public void close() {
            super.close();
            table = null;
        }
    }

    /**
     * INNER equi-join that builds its hash table on the left input and probes it with the right
     * input (chosen when the left input is estimated to be smaller). Output rows are still
     * left columns followed by right columns.
     */
    public static final class HashJoinBuildLeft implements Operator {
        private final Operator left;
        private final Operator right;
        private final Evaluator[] leftKeys;
        private final Evaluator[] rightKeys;
        private final List<UnaryOperator<Object>> leftNorm;
        private final List<UnaryOperator<Object>> rightNorm;
        private final Evaluator residual;
        private final ExecContext ctx;
        private Map<Object, List<Object[]>> table;
        private long reserved;
        private long produced;
        private Object[] rightRow;
        private List<Object[]> candidates = List.of();
        private int next;

        public HashJoinBuildLeft(Operator left, Operator right, Evaluator[] leftKeys, Evaluator[] rightKeys,
                                 List<UnaryOperator<Object>> leftNorm, List<UnaryOperator<Object>> rightNorm,
                                 Evaluator residual, ExecContext ctx) {
            this.left = left;
            this.right = right;
            this.leftKeys = leftKeys;
            this.rightKeys = rightKeys;
            this.leftNorm = leftNorm;
            this.rightNorm = rightNorm;
            this.residual = residual;
            this.ctx = ctx;
        }

        @Override
        public void open() {
            produced = 0;
            candidates = List.of();
            table = new HashMap<>();
            left.open();
            Object[] r;
            while ((r = left.next()) != null) {
                ctx.checkpoint();
                Object k = HashJoin.key(r, leftKeys, leftNorm);
                if (k == null) {
                    continue;
                }
                long size = ExecContext.estimateRow(r) + 32;
                ctx.reserve(size);
                reserved += size;
                table.computeIfAbsent(k, x -> new ArrayList<>(2)).add(r);
            }
            right.open();
        }

        @Override
        public Object[] next() {
            while (true) {
                while (next < candidates.size()) {
                    Object[] combined = JoinBase.concat(candidates.get(next++), rightRow);
                    ctx.checkpoint();
                    if (residual == null || Boolean.TRUE.equals(residual.eval(combined))) {
                        if (++produced > ctx.maxJoinRows()) {
                            throw new PolyQueryException(ErrorCode.RESOURCE_LIMIT,
                                    "join produced more than " + ctx.maxJoinRows() + " rows");
                        }
                        return combined;
                    }
                }
                rightRow = right.next();
                if (rightRow == null) {
                    return null;
                }
                Object k = HashJoin.key(rightRow, rightKeys, rightNorm);
                candidates = k == null ? List.of() : table.getOrDefault(k, List.of());
                next = 0;
            }
        }

        @Override
        public void close() {
            left.close();
            right.close();
            ctx.release(reserved);
            reserved = 0;
            table = null;
            candidates = List.of();
        }
    }

    /**
     * Sort-merge equi-join (INNER or LEFT). Both inputs are materialized (right first) with their
     * key tuples, sorted stably by key and merged; each run of equal left keys is paired with the
     * run of equal right keys. Rows with a NULL key component never match (LEFT join: they are
     * padded, after the merged rows).
     */
    public static final class MergeJoin implements Operator {
        private record Keyed(Object[] key, Object[] row) {
        }

        private final Operator left;
        private final Operator right;
        private final Evaluator[] leftKeys;
        private final Evaluator[] rightKeys;
        private final Comparator<Object[]> leftOrder;
        private final Comparator<Object[]> rightOrder;
        private final Comparator<Object[]> crossOrder;
        private final Evaluator residual;
        private final boolean leftOuter;
        private final int rightWidth;
        private final ExecContext ctx;
        private List<Keyed> lefts;
        private List<Keyed> rights;
        private List<Object[]> unmatchedNullKeys;
        private long reserved;
        private long produced;
        private int li;
        private int runStart;
        private int runEnd;
        private int ri;
        private boolean matched;
        private int nullPos;

        /**
         * @param leftOrder  orders left key tuples
         * @param rightOrder orders right key tuples
         * @param crossOrder compares a left key tuple with a right key tuple
         */
        public MergeJoin(Operator left, Operator right, Evaluator[] leftKeys, Evaluator[] rightKeys,
                         Comparator<Object[]> leftOrder, Comparator<Object[]> rightOrder,
                         Comparator<Object[]> crossOrder, Evaluator residual, boolean leftOuter, int rightWidth,
                         ExecContext ctx) {
            this.left = left;
            this.right = right;
            this.leftKeys = leftKeys;
            this.rightKeys = rightKeys;
            this.leftOrder = leftOrder;
            this.rightOrder = rightOrder;
            this.crossOrder = crossOrder;
            this.residual = residual;
            this.leftOuter = leftOuter;
            this.rightWidth = rightWidth;
            this.ctx = ctx;
        }

        private List<Keyed> materialize(Operator input, Evaluator[] keys, List<Object[]> nullKeyed) {
            List<Keyed> out = new ArrayList<>();
            Object[] r;
            while ((r = input.next()) != null) {
                ctx.checkpoint();
                Object[] k = new Object[keys.length];
                boolean hasNull = false;
                for (int i = 0; i < k.length && !hasNull; i++) {
                    k[i] = keys[i].eval(r);
                    hasNull = k[i] == null;
                }
                long size = ExecContext.estimateRow(r) + ExecContext.estimateRow(k) + 32;
                ctx.reserve(size);
                reserved += size;
                if (!hasNull) {
                    out.add(new Keyed(k, r));
                } else if (nullKeyed != null) {
                    nullKeyed.add(r);
                }
            }
            return out;
        }

        @Override
        public void open() {
            produced = 0;
            right.open();
            rights = materialize(right, rightKeys, null);
            left.open();
            unmatchedNullKeys = new ArrayList<>();
            lefts = materialize(left, leftKeys, leftOuter ? unmatchedNullKeys : null);
            ctx.checkNow();
            rights.sort((a, b) -> {
                ctx.checkpoint();
                return rightOrder.compare(a.key(), b.key());
            });
            lefts.sort((a, b) -> {
                ctx.checkpoint();
                return leftOrder.compare(a.key(), b.key());
            });
            li = -1;
            runStart = 0;
            runEnd = 0;
            ri = 0;
            nullPos = 0;
            advanceLeft();
        }

        /** Moves to the next left row and positions the run of right rows with an equal key. */
        private void advanceLeft() {
            li++;
            matched = false;
            if (li >= lefts.size()) {
                return;
            }
            Object[] key = lefts.get(li).key();
            if (li > 0 && leftOrder.compare(lefts.get(li - 1).key(), key) == 0) {
                ri = runStart; // same key as the previous left row: reuse its run
                return;
            }
            int pos = runEnd;
            while (pos < rights.size() && crossOrder.compare(key, rights.get(pos).key()) > 0) {
                pos++;
            }
            runStart = pos;
            while (pos < rights.size() && crossOrder.compare(key, rights.get(pos).key()) == 0) {
                pos++;
            }
            runEnd = pos;
            ri = runStart;
        }

        @Override
        public Object[] next() {
            while (li < lefts.size()) {
                Object[] leftRow = lefts.get(li).row();
                while (ri < runEnd) {
                    Object[] combined = JoinBase.concat(leftRow, rights.get(ri++).row());
                    ctx.checkpoint();
                    if (residual == null || Boolean.TRUE.equals(residual.eval(combined))) {
                        matched = true;
                        return emit(combined);
                    }
                }
                boolean pad = leftOuter && !matched;
                advanceLeft();
                if (pad) {
                    return emit(JoinBase.concat(leftRow, new Object[rightWidth]));
                }
            }
            if (nullPos < unmatchedNullKeys.size()) {
                return emit(JoinBase.concat(unmatchedNullKeys.get(nullPos++), new Object[rightWidth]));
            }
            return null;
        }

        private Object[] emit(Object[] row) {
            if (++produced > ctx.maxJoinRows()) {
                throw new PolyQueryException(ErrorCode.RESOURCE_LIMIT,
                        "join produced more than " + ctx.maxJoinRows() + " rows");
            }
            return row;
        }

        @Override
        public void close() {
            left.close();
            right.close();
            ctx.release(reserved);
            reserved = 0;
            lefts = null;
            rights = null;
            unmatchedNullKeys = null;
        }
    }
}
