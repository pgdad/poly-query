package polyquery.api;

import java.util.List;

/**
 * The schema of a table: its name, row count, columns and the names of its indexes.
 *
 * @param name     table name
 * @param rowCount number of rows
 * @param columns  columns in table order
 * @param indexes  the table's indexes (from {@code CREATE INDEX} or an opened PQCF file)
 */
public record TableSchema(String name, long rowCount, List<Column> columns, List<IndexInfo> indexes) {
    /**
     * An index of a table.
     *
     * @param name   index name (global in the instance)
     * @param column indexed column
     * @param kind   {@code HASH} or {@code BTREE}
     */
    public record IndexInfo(String name, String column, String kind) {
    }

    public TableSchema {
        columns = List.copyOf(columns);
        indexes = List.copyOf(indexes);
    }
}
