package polyquery.storage;

/** Column-oriented in-memory storage: one vector per column, a single row group. */
public final class ColumnarData implements TableData {
    private final ColumnVector[] columns;
    private final int rowCount;

    public ColumnarData(ColumnVector[] columns, int rowCount) {
        this.columns = columns.clone();
        this.rowCount = rowCount;
    }

    public ColumnVector column(int i) {
        return columns[i];
    }

    @Override
    public Layout layout() {
        return Layout.COLUMN;
    }

    @Override
    public int rowCount() {
        return rowCount;
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
        return rowCount;
    }

    @Override
    public ColumnVector chunk(int group, int column) {
        return columns[column];
    }

    @Override
    public long estimatedBytes() {
        long total = 0;
        for (ColumnVector c : columns) {
            total += c.estimatedBytes();
        }
        return total;
    }
}
