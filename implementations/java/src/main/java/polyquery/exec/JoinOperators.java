package polyquery.exec;

import java.util.ArrayList;
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

        private static Object[] concat(Object[] a, Object[] b) {
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

        private static Object key(Object[] row, Evaluator[] keys, List<UnaryOperator<Object>> norm) {
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
}
