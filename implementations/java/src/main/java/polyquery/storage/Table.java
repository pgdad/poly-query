package polyquery.storage;

import java.util.List;
import polyquery.common.Names;
import polyquery.index.Index;
import polyquery.types.DataType;

/**
 * An immutable table snapshot: schema, stored rows ({@link TableData}, row or column layout),
 * the indexes defined on it and its (lazily computed) statistics. Catalog changes such as
 * CREATE INDEX publish a new snapshot sharing the same data and statistics.
 */
public final class Table {
    private final String name;
    private final List<ColumnSchema> columns;
    private final TableData data;
    private final List<Index> indexes;
    private final TableStatistics stats;

    public Table(String name, List<ColumnSchema> columns, TableData data) {
        this(name, columns, data, List.of(), null);
    }

    /** A column-layout table over the given vectors. */
    public Table(String name, List<ColumnSchema> columns, ColumnVector[] vectors, int rowCount) {
        this(name, columns, new ColumnarData(vectors, rowCount));
    }

    private Table(String name, List<ColumnSchema> columns, TableData data, List<Index> indexes,
                  TableStatistics stats) {
        this.name = name;
        this.columns = List.copyOf(columns);
        this.data = data;
        this.indexes = List.copyOf(indexes);
        this.stats = stats != null ? stats : new TableStatistics(data, this.columns);
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

    public DataType columnType(int i) {
        return columns.get(i).type();
    }

    public TableData data() {
        return data;
    }

    public Layout layout() {
        return data.layout();
    }

    public int rowCount() {
        return data.rowCount();
    }

    public TableStatistics stats() {
        return stats;
    }

    public List<Index> indexes() {
        return indexes;
    }

    /** Same snapshot under another name, without indexes. */
    public Table renamed(String newName) {
        return new Table(newName, columns, data, List.of(), stats);
    }

    /** Same data and statistics with a different set of indexes. */
    public Table withIndexes(List<Index> newIndexes) {
        return new Table(name, columns, data, newIndexes, stats);
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

    public static String key(String name) {
        return Names.key(name);
    }
}
