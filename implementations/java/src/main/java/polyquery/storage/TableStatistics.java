package polyquery.storage;

import java.util.List;
import polyquery.types.DataType;
import polyquery.types.Values;

/**
 * Per-table statistics (indexes-and-planning.md §3): row count plus, per column, null count,
 * min, max and distinct count. Column statistics are computed on first use and cached; the
 * object is shared by all snapshots of a table that share its data.
 */
public final class TableStatistics {
    private final TableData data;
    private final List<ColumnSchema> schema;
    private final ColumnStats[] columns;

    public TableStatistics(TableData data, List<ColumnSchema> schema) {
        this.data = data;
        this.schema = schema;
        this.columns = new ColumnStats[schema.size()];
    }

    public long rowCount() {
        return data.rowCount();
    }

    public ColumnStats column(int i) {
        synchronized (columns) {
            if (columns[i] != null) {
                return columns[i];
            }
        }
        ColumnStats s = compute(i);
        synchronized (columns) {
            columns[i] = s;
        }
        return s;
    }

    private ColumnStats compute(int column) {
        DataType type = schema.get(column).type();
        long nulls = 0;
        Object min = null;
        Object max = null;
        DistinctCounter distinct = new DistinctCounter();
        for (int g = 0; g < data.groupCount(); g++) {
            ColumnVector v = data.chunk(g, column);
            int n = data.groupSize(g);
            for (int i = 0; i < n; i++) {
                Object x = v.get(i);
                if (x == null) {
                    nulls++;
                    continue;
                }
                if (x instanceof Double d && d == 0.0) {
                    x = 0.0;
                }
                distinct.add(x);
                if (min == null || Values.compare(x, min, type) < 0) {
                    min = x;
                }
                if (max == null || Values.compare(x, max, type) > 0) {
                    max = x;
                }
            }
        }
        return new ColumnStats(nulls, distinct.count(), min, max);
    }
}
