package polyquery.exec.vector;

import java.util.List;
import polyquery.common.PolyQueryException;
import polyquery.exec.ExecContext;
import polyquery.exec.Operator;
import polyquery.plan.BoundExpr;
import polyquery.storage.ColumnSchema;

/** Streaming batch operators and the adapters between row and batch execution. */
final class BatchOperators {
    private BatchOperators() {
    }

    /**
     * Keeps the rows whose predicate is TRUE by narrowing the selection vector (no copying). The
     * conjuncts of the predicate are evaluated one after the other, each only on the rows no
     * earlier conjunct made FALSE — exactly the rows the row engine's short-circuit AND
     * evaluates — so most rows are discarded by the first, cheapest loops. A data error falls
     * back to row-by-row evaluation of the whole predicate ({@link BatchExprs}).
     */
    static final class Filter implements BatchOperator {
        private final BatchOperator input;
        private final VecExpr[] conjuncts;
        private final BatchExprs predicate;
        private final Batch out;
        private int[] sel = new int[0];
        private int[] tmp = new int[0];
        private boolean[] sawNull = new boolean[0];

        Filter(BatchOperator input, VecCompiler compiler, BoundExpr predicate, int width) {
            this.input = input;
            List<BoundExpr> parts = polyquery.plan.BoundExprs.conjuncts(predicate);
            this.conjuncts = new VecExpr[parts.size()];
            for (int i = 0; i < conjuncts.length; i++) {
                conjuncts[i] = compiler.compile(parts.get(i));
            }
            this.predicate = new BatchExprs(compiler, List.of(predicate));
            this.out = new Batch(width);
        }

        @Override
        public void open() {
            input.open();
        }

        /** Selects the rows where every conjunct is TRUE into {@code sel}; returns their number. */
        private int select(Batch in) {
            int[] cur = in.sel;
            int n = in.count;
            int[] dst = sel;
            boolean anyNull = false;
            for (VecExpr c : conjuncts) {
                Vec r = c.eval(in, cur, n);
                long[] v = r.longs;
                int m = 0;
                if (!r.hasNulls) {
                    if (cur == null) {
                        for (int i = 0; i < n; i++) {
                            dst[m] = i;
                            m += (int) v[i];
                        }
                    } else {
                        for (int k = 0; k < n; k++) {
                            int i = cur[k];
                            dst[m] = i;
                            m += (int) v[i];
                        }
                    }
                } else {
                    // NULL rows stay for the later conjuncts (AND continues on NULL) but never pass
                    for (int k = 0; k < n; k++) {
                        int i = cur == null ? k : cur[k];
                        if (r.nulls[i]) {
                            sawNull[i] = true;
                            anyNull = true;
                            dst[m++] = i;
                        } else if (v[i] == 1) {
                            dst[m++] = i;
                        }
                    }
                }
                cur = dst;
                dst = dst == sel ? tmp : sel;
                n = m;
                if (n == 0) {
                    break;
                }
            }
            if (cur != sel) {
                System.arraycopy(cur, 0, sel, 0, n);
            }
            if (anyNull) {
                int m = 0;
                for (int k = 0; k < n; k++) {
                    int i = sel[k];
                    if (!sawNull[i]) {
                        sel[m++] = i;
                    }
                }
                n = m;
                java.util.Arrays.fill(sawNull, false);
            }
            return n;
        }

        @Override
        public Batch next() {
            Batch in;
            while ((in = input.next()) != null) {
                if (in.count == 0) {
                    if (in.error == null) {
                        continue;
                    }
                    out.cols = in.cols;
                    out.size = in.size;
                    out.sel = null;
                    out.count = 0;
                    out.error = in.error;
                    return out;
                }
                if (sel.length < in.size) {
                    sel = new int[Math.max(in.size, 16)];
                    tmp = new int[sel.length];
                    sawNull = new boolean[sel.length];
                }
                int m;
                try {
                    m = select(in);
                } catch (PolyQueryException e) {
                    if (!BatchExprs.deferrable(e)) {
                        throw e;
                    }
                    java.util.Arrays.fill(sawNull, false);
                    Vec p = predicate.evalRows(in)[0]; // exact: finds the failing row, truncates `in`
                    m = 0;
                    for (int k = 0; k < in.count; k++) {
                        int i = in.pos(k);
                        if (!p.isNull(i) && p.longs[i] == 1) {
                            sel[m++] = i;
                        }
                    }
                }
                out.cols = in.cols;
                out.size = in.size;
                out.sel = m == in.size && in.sel == null ? null : sel;
                out.count = m;
                out.error = in.error;
                if (m > 0 || out.error != null) {
                    return out;
                }
            }
            return null;
        }

        @Override
        public void close() {
            input.close();
        }
    }

    /** Evaluates the output expressions; the selection of the input is kept. */
    static final class Project implements BatchOperator {
        private final BatchOperator input;
        private final BatchExprs exprs;
        private final Batch out;

        Project(BatchOperator input, VecCompiler compiler, List<BoundExpr> exprs) {
            this.input = input;
            this.exprs = new BatchExprs(compiler, exprs);
            this.out = new Batch(exprs.size());
        }

        @Override
        public void open() {
            input.open();
        }

        @Override
        public Batch next() {
            Batch in;
            while ((in = input.next()) != null) {
                if (in.count == 0 && in.error == null) {
                    continue;
                }
                if (in.count > 0) {
                    Vec[] r = exprs.eval(in);
                    System.arraycopy(r, 0, out.cols, 0, r.length);
                }
                out.size = in.size;
                out.sel = in.sel;
                out.count = in.count;
                out.error = in.error;
                return out;
            }
            return null;
        }

        @Override
        public void close() {
            input.close();
        }
    }

    /** OFFSET then LIMIT over the active rows (limit < 0 = unlimited); LIMIT 0 never reads its input. */
    static final class Limit implements BatchOperator {
        private final BatchOperator input;
        private final long offset;
        private final long limit;
        private final Batch out;
        private int[] sel = new int[0];
        private long skipped;
        private long produced;

        Limit(BatchOperator input, long offset, long limit, int width) {
            this.input = input;
            this.offset = offset;
            this.limit = limit;
            this.out = new Batch(width);
        }

        @Override
        public void open() {
            skipped = 0;
            produced = 0;
            if (limit != 0) {
                input.open();
            }
        }

        @Override
        public Batch next() {
            if (limit >= 0 && produced >= limit) {
                return null;
            }
            Batch in;
            while ((in = input.next()) != null) {
                int k0 = 0;
                if (skipped < offset) {
                    k0 = (int) Math.min(offset - skipped, in.count);
                    skipped += k0;
                }
                int avail = in.count - k0;
                int take = limit < 0 ? avail : (int) Math.min(avail, limit - produced);
                if (sel.length < take) {
                    sel = new int[Math.max(take, 16)];
                }
                for (int k = 0; k < take; k++) {
                    sel[k] = in.pos(k0 + k);
                }
                produced += take;
                out.cols = in.cols;
                out.size = in.size;
                out.sel = sel;
                out.count = take;
                out.error = k0 + take == in.count ? in.error : null;
                if (take > 0 || out.error != null) {
                    return out;
                }
            }
            return null;
        }

        @Override
        public void close() {
            if (limit != 0) {
                input.close();
            }
        }
    }

    /** Presents a batch operator as a row operator (rows are boxed into fresh arrays). */
    static final class BatchToRow implements Operator {
        private final BatchOperator input;
        private final int width;
        private Batch current;
        private int k;

        BatchToRow(BatchOperator input, int width) {
            this.input = input;
            this.width = width;
        }

        @Override
        public void open() {
            input.open();
            current = null;
            k = 0;
        }

        @Override
        public Object[] next() {
            while (true) {
                if (current != null) {
                    if (k < current.count) {
                        int i = current.pos(k++);
                        Object[] row = new Object[width];
                        Vec[] cols = current.cols;
                        for (int c = 0; c < width; c++) {
                            if (cols[c] != null) {
                                row[c] = cols[c].get(i);
                            }
                        }
                        return row;
                    }
                    if (current.error != null) {
                        throw current.error;
                    }
                }
                current = input.next();
                k = 0;
                if (current == null) {
                    return null;
                }
            }
        }

        @Override
        public void close() {
            input.close();
            current = null;
        }
    }

    /** Presents a row operator as a batch operator. */
    static final class RowToBatch implements BatchOperator {
        private final Operator input;
        private final int batchSize;
        private final Batch batch;
        private boolean done;

        RowToBatch(Operator input, List<ColumnSchema> schema, int batchSize) {
            this.input = input;
            this.batchSize = batchSize;
            this.batch = new Batch(schema.size());
            for (int c = 0; c < schema.size(); c++) {
                batch.cols[c] = new Vec(schema.get(c).type(), batchSize);
            }
        }

        @Override
        public void open() {
            input.open();
            done = false;
        }

        @Override
        public Batch next() {
            if (done) {
                return null;
            }
            for (Vec v : batch.cols) {
                v.nullMask(batchSize);
            }
            int n = 0;
            RuntimeException error = null;
            try {
                while (n < batchSize) {
                    Object[] row = input.next();
                    if (row == null) {
                        done = true;
                        break;
                    }
                    for (int c = 0; c < batch.cols.length; c++) {
                        batch.cols[c].set(n, row[c]);
                    }
                    n++;
                }
            } catch (PolyQueryException e) {
                if (!BatchExprs.deferrable(e)) {
                    throw e;
                }
                done = true;
                error = e; // raised after the rows produced before it
            }
            batch.reset(n);
            batch.error = error;
            return n == 0 && error == null ? null : batch;
        }

        @Override
        public void close() {
            input.close();
        }
    }

    /** Checks cancellation between batches of a long-running blocking operator. */
    static void checkpoint(ExecContext ctx) {
        ctx.checkNow();
    }
}
