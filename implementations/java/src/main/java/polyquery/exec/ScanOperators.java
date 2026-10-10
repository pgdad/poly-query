package polyquery.exec;

import java.util.List;
import polyquery.index.Index;
import polyquery.index.KeyDomain;
import polyquery.index.KeyPredicate;
import polyquery.physical.PhysicalPlan;
import polyquery.storage.ColumnCursor;
import polyquery.storage.ColumnVector;
import polyquery.storage.RowData;
import polyquery.storage.Table;
import polyquery.storage.TableData;
import polyquery.types.DataType;

/**
 * Leaf operators reading stored tables. Output rows have the table's full width; only the
 * requested column slots are filled (column pruning), the others stay null.
 */
public final class ScanOperators {
    private ScanOperators() {
    }

    private static int[] allColumns(Table table) {
        int[] out = new int[table.columnCount()];
        for (int i = 0; i < out.length; i++) {
            out[i] = i;
        }
        return out;
    }

    /** Sequential scan over row groups, skipping groups whose statistics exclude a filter. */
    public static final class TableScan implements Operator {
        private final Table table;
        private final TableData data;
        private final int width;
        private final int[] columns;
        private final List<PhysicalPlan.ColumnFilter> skipFilters;
        private final ExecContext ctx;
        private final ColumnVector[] vectors;
        private int group;
        private int pos;
        private int size;
        private int start;

        public TableScan(PhysicalPlan.TableScan plan, ExecContext ctx) {
            this.table = plan.table();
            this.data = table.data();
            this.width = table.columnCount();
            this.columns = plan.columns() == null ? allColumns(table) : plan.columns();
            this.skipFilters = plan.skipFilters();
            this.ctx = ctx;
            this.vectors = new ColumnVector[columns.length];
        }

        @Override
        public void open() {
            group = -1;
            pos = 0;
            size = 0;
        }

        private boolean nextGroup() {
            while (++group < data.groupCount()) {
                ctx.checkNow();
                if (data.groupSize(group) == 0 || skip(group)) {
                    continue;
                }
                start = data.groupStart(group);
                size = data.groupSize(group);
                pos = 0;
                if (!(data instanceof RowData)) {
                    for (int k = 0; k < columns.length; k++) {
                        vectors[k] = data.chunk(group, columns[k]);
                    }
                }
                return true;
            }
            return false;
        }

        /** True if the chunk statistics prove that no row of the group satisfies a filter. */
        private boolean skip(int g) {
            for (PhysicalPlan.ColumnFilter f : skipFilters) {
                Object[] bounds = data.chunkBounds(g, f.column());
                if (bounds == null) {
                    continue;
                }
                DataType type = table.columnType(f.column());
                if (!f.predicate().overlaps(KeyDomain.key(bounds[0], type), KeyDomain.key(bounds[1], type))) {
                    return true;
                }
            }
            return false;
        }

        @Override
        public Object[] next() {
            while (pos >= size) {
                if (!nextGroup()) {
                    return null;
                }
            }
            ctx.checkpoint();
            Object[] out = new Object[width];
            if (data instanceof RowData rows) {
                Object[] stored = rows.row(start + pos);
                for (int c : columns) {
                    out[c] = stored[c];
                }
            } else {
                for (int k = 0; k < columns.length; k++) {
                    out[columns[k]] = vectors[k].get(pos);
                }
            }
            pos++;
            return out;
        }
    }

    /** Fetches the rows found by an index lookup, in ascending row order. */
    public static final class IndexScan implements Operator {
        private final Table table;
        private final Index index;
        private final KeyPredicate lookup;
        private final int width;
        private final int[] columns;
        private final ExecContext ctx;
        private int[] rowIds;
        private ColumnCursor[] cursors;
        private int next;

        public IndexScan(PhysicalPlan.IndexScan plan, ExecContext ctx) {
            this.table = plan.table();
            this.index = plan.index();
            this.lookup = plan.lookup();
            this.width = table.columnCount();
            this.columns = plan.columns() == null ? allColumns(table) : plan.columns();
            this.ctx = ctx;
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
        public Object[] next() {
            if (next >= rowIds.length) {
                return null;
            }
            ctx.checkpoint();
            int row = rowIds[next++];
            Object[] out = new Object[width];
            if (table.data() instanceof RowData rows) {
                Object[] stored = rows.row(row);
                for (int c : columns) {
                    out[c] = stored[c];
                }
            } else {
                for (int k = 0; k < columns.length; k++) {
                    out[columns[k]] = cursors[k].get(row);
                }
            }
            return out;
        }
    }
}
