package polyquery.storage;

/**
 * Reads one column of a {@link TableData} by global row id. Access is cheapest when row ids
 * are visited in ascending order (the current row group's chunk is cached).
 */
public final class ColumnCursor {
    private final TableData data;
    private final int column;
    private int group = -1;
    private int start;
    private int end;
    private ColumnVector chunk;

    public ColumnCursor(TableData data, int column) {
        this.data = data;
        this.column = column;
    }

    public Object get(int row) {
        if (row < start || row >= end) {
            seek(row);
        }
        return chunk.get(row - start);
    }

    private void seek(int row) {
        int lo = 0;
        int hi = data.groupCount() - 1;
        if (group >= 0 && row >= end && group + 1 <= hi && row < data.groupStart(group + 1) + data.groupSize(group + 1)) {
            lo = group + 1;
            hi = group + 1;
        }
        while (lo < hi) {
            int mid = (lo + hi + 1) >>> 1;
            if (data.groupStart(mid) <= row) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        group = lo;
        start = data.groupStart(lo);
        end = start + data.groupSize(lo);
        chunk = data.chunk(lo, column);
    }
}
