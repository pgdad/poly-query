package polyquery.storage;

import polyquery.common.Names;
import java.util.List;
import polyquery.types.DataType;

/** An immutable in-memory table stored column-wise. */
public final class Table {
    private final String name;
    private final List<ColumnSchema> columns;
    private final ColumnVector[] data;
    private final int rowCount;

    public Table(String name, List<ColumnSchema> columns, ColumnVector[] data, int rowCount) {
        this.name = name;
        this.columns = List.copyOf(columns);
        this.data = data.clone();
        this.rowCount = rowCount;
    }

    public String name() {
        return name;
    }

    public List<ColumnSchema> columns() {
        return columns;
    }

    public int columnCount() {
        return columns.size();
    }

    public ColumnVector column(int i) {
        return data[i];
    }

    public DataType columnType(int i) {
        return columns.get(i).type();
    }

    public int rowCount() {
        return rowCount;
    }

    /** Index of a column by case-insensitive name, or -1. */
    public int findColumn(String columnName) {
        for (int i = 0; i < columns.size(); i++) {
            if (Names.equal(columns.get(i).name(), columnName)) {
                return i;
            }
        }
        return -1;
    }

    /** Same data under a different name. */
    public Table renamed(String newName) {
        return new Table(newName, columns, data, rowCount);
    }

    public static String key(String name) {
        return Names.key(name);
    }
}
