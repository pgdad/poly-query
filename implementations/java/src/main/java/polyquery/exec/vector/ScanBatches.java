package polyquery.exec.vector;

import java.util.Arrays;
import java.util.BitSet;
import java.util.List;
import polyquery.exec.ExecContext;
import polyquery.index.Index;
import polyquery.physical.PhysicalPlan;
import polyquery.storage.ColumnCursor;
import polyquery.storage.ColumnVector;
import polyquery.storage.Table;
import polyquery.storage.TableData;

/** Leaf batch operators reading stored tables; only the slots of the scanned columns are filled. */
final class ScanBatches {
    private ScanBatches() {
    }

    private static int[] columns(int[] cols, Table table) {
        if (cols != null) {
            return cols;
        }
        int[] all = new int[table.columnCount()];
        for (int i = 0; i < all.length; i++) {
            all[i] = i;
        }
        return all;
    }

    /** Fills positions {@code 0..n-1} of {@code v} with rows {@code from..from+n-1} of a chunk. */
    static void load(ColumnVector chunk, int from, int n, Vec v, int cap) {
        switch (chunk) {
            case ColumnVector.LongVector c -> {
                System.arraycopy(c.values(), from, v.longs, 0, n);
                loadNulls(c.nulls(), from, n, v, cap);
            }
            case ColumnVector.DoubleVector c -> {
                System.arraycopy(c.values(), from, v.doubles, 0, n);
                loadNulls(c.nulls(), from, n, v, cap);
            }
            case ColumnVector.IntVector c -> {
                int[] src = c.values();
                long[] dst = v.longs;
                for (int i = 0; i < n; i++) {
                    dst[i] = src[from + i];
                }
                loadNulls(c.nulls(), from, n, v, cap);
            }
            case ColumnVector.BooleanVector c -> {
                BitSet bits = c.bits();
                long[] dst = v.longs;
                for (int i = 0; i < n; i++) {
                    dst[i] = bits.get(from + i) ? 1 : 0;
                }
                loadNulls(c.nulls(), from, n, v, cap);
            }
            case ColumnVector.DictStringVector c -> {
                v.toDict(c.dictionary(), cap);
                System.arraycopy(c.codes(), from, v.codes, 0, n);
                loadNulls(c.nulls(), from, n, v, cap);
            }
            case ColumnVector.StringVector c -> {
                if (v.kind != Vec.Kind.OBJECT) {
                    v.toObjects(cap);
                }
                String[] src = c.values();
                System.arraycopy(src, from, v.objects, 0, n);
                boolean any = false;
                for (int i = 0; i < n && !any; i++) {
                    any = src[from + i] == null;
                }
                if (any) {
                    boolean[] m = v.nullMask(cap);
                    for (int i = 0; i < n; i++) {
                        m[i] = src[from + i] == null;
                    }
                } else {
                    v.hasNulls = false;
                }
            }
            default -> {
                if (v.kind == Vec.Kind.DICT) {
                    v.toObjects(cap);
                }
                v.nullMask(cap);
                for (int i = 0; i < n; i++) {
                    v.set(i, chunk.get(from + i));
                }
            }
        }
    }

    private static void loadNulls(BitSet nulls, int from, int n, Vec v, int cap) {
        int first = nulls.nextSetBit(from);
        if (first < 0 || first >= from + n) {
            v.hasNulls = false;
            return;
        }
        boolean[] m = v.nullMask(cap);
        long[] words = nulls.get(from, from + n).toLongArray(); // the range's bits, word by word
        int full = Math.min(n, words.length * 64);
        for (int i = 0; i < full; i++) {
            m[i] = ((words[i >>> 6] >>> i) & 1) != 0;
        }
        java.util.Arrays.fill(m, full, n, false);
    }

    /**
     * Sequential scan over morsels (all morsels of the table in order, or the morsels a parallel
     * worker assigns with {@link #setMorsel}).
     */
    static final class TableScan implements BatchOperator {
        private final TableData data;
        private final int[] columns;
        private final ExecContext ctx;
        private final int batchSize;
        private final List<Morsel> morsels;
        private final Batch batch;
        private final Vec[] vecs;
        private int next;
        private Morsel current;
        private int pos;
        private boolean single;

        TableScan(PhysicalPlan.TableScan plan, ExecContext ctx, int batchSize, List<Morsel> morsels) {
            Table table = plan.table();
            this.data = table.data();
            this.columns = columns(plan.columns(), table);
            this.ctx = ctx;
            this.batchSize = batchSize;
            this.morsels = morsels;
            this.batch = new Batch(table.columnCount());
            this.vecs = new Vec[columns.length];
            for (int k = 0; k < columns.length; k++) {
                vecs[k] = new Vec(table.columnType(columns[k]), batchSize);
                batch.cols[columns[k]] = vecs[k];
            }
        }

        /** Restricts the scan to one morsel (parallel workers); takes effect at the next {@link #open()}. */
        void setMorsel(Morsel m) {
            current = m;
            single = true;
        }

        @Override
        public void open() {
            if (!single) {
                next = 0;
                current = null;
            }
            pos = current == null ? 0 : current.from();
        }

        @Override
        public Batch next() {
            while (current == null || pos >= current.to()) {
                if (single || next >= morsels.size()) {
                    return null;
                }
                current = morsels.get(next++);
                pos = current.from();
            }
            ctx.checkNow();
            int n = Math.min(batchSize, current.to() - pos);
            for (int k = 0; k < columns.length; k++) {
                load(data.chunk(current.group(), columns[k]), pos, n, vecs[k], batchSize);
            }
            pos += n;
            batch.reset(n);
            return batch;
        }
    }

    /** Rows found by an index lookup, in ascending row order. */
    static final class IndexScan implements BatchOperator {
        private final Table table;
        private final Index index;
        private final polyquery.index.KeyPredicate lookup;
        private final int[] columns;
        private final ExecContext ctx;
        private final int batchSize;
        private final Batch batch;
        private final Vec[] vecs;
        private int[] rowIds;
        private ColumnCursor[] cursors;
        private int next;

        IndexScan(PhysicalPlan.IndexScan plan, ExecContext ctx, int batchSize) {
            this.table = plan.table();
            this.index = plan.index();
            this.lookup = plan.lookup();
            this.columns = columns(plan.columns(), table);
            this.ctx = ctx;
            this.batchSize = batchSize;
            this.batch = new Batch(table.columnCount());
            this.vecs = new Vec[columns.length];
            for (int k = 0; k < columns.length; k++) {
                vecs[k] = new Vec(table.columnType(columns[k]), batchSize);
                batch.cols[columns[k]] = vecs[k];
            }
        }

        @Override
        public void open() {
            if (rowIds == null) {
                rowIds = index.structure().lookup(lookup);
                ctx.reserve(4L * rowIds.length);
            }
            cursors = new ColumnCursor[columns.length];
            for (int k = 0; k < columns.length; k++) {
                cursors[k] = new ColumnCursor(table.data(), columns[k]);
            }
            next = 0;
        }

        @Override
        public Batch next() {
            if (next >= rowIds.length) {
                return null;
            }
            ctx.checkNow();
            int n = Math.min(batchSize, rowIds.length - next);
            for (int k = 0; k < columns.length; k++) {
                Vec v = vecs[k];
                if (v.kind == Vec.Kind.DICT) {
                    v.toObjects(batchSize);
                }
                v.nullMask(batchSize);
                for (int i = 0; i < n; i++) {
                    v.set(i, cursors[k].get(rowIds[next + i]));
                }
            }
            next += n;
            batch.reset(n);
            return batch;
        }
    }

    /** One row without columns (SELECT without FROM). */
    static final class SingleRow implements BatchOperator {
        private final Batch batch = new Batch(0);
        private boolean done;

        @Override
        public void open() {
            done = false;
        }

        @Override
        public Batch next() {
            if (done) {
                return null;
            }
            done = true;
            batch.reset(1);
            return batch;
        }
    }
}
