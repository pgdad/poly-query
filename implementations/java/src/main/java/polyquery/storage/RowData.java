package polyquery.storage;

import java.util.List;
import polyquery.types.DataType;

/** Row-oriented in-memory storage: an array of row tuples in the runtime value representation. */
public final class RowData implements TableData {
    private final Object[][] rows;
    private final DataType[] types;

    public RowData(Object[][] rows, List<ColumnSchema> schema) {
        this.rows = rows;
        this.types = new DataType[schema.size()];
        for (int i = 0; i < types.length; i++) {
            types[i] = schema.get(i).type();
        }
    }

    /** The stored tuple of a row; callers must not modify it. */
    public Object[] row(int i) {
        return rows[i];
    }

    @Override
    public Layout layout() {
        return Layout.ROW;
    }

    @Override
    public int rowCount() {
        return rows.length;
    }

    @Override
    public int groupCount() {
        return 1;
    }

    @Override
    public int groupStart(int group) {
        return 0;
    }

    @Override
    public int groupSize(int group) {
        return rows.length;
    }

    @Override
    public ColumnVector chunk(int group, int column) {
        return ColumnVector.rowView(types[column], rows, column);
    }

    @Override
    public long estimatedBytes() {
        long total = 0;
        for (Object[] r : rows) {
            total += 16 + 8L * r.length;
            for (Object v : r) {
                if (v instanceof String s) {
                    total += 40 + s.length();
                } else if (v != null) {
                    total += 16;
                }
            }
        }
        return total;
    }
}
