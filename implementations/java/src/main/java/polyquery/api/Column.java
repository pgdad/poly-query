package polyquery.api;

import java.util.Objects;

/**
 * A named, typed column of a table or a query result.
 *
 * @param name the column name as reported by the engine
 * @param type the column's type
 */
public record Column(String name, ColumnType type) {
    public Column {
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(type, "type");
    }

    /** A column whose type is given by name, e.g. {@code Column.of("amount", "DECIMAL(18,2)")}. */
    public static Column of(String name, String type) {
        return new Column(name, ColumnType.parse(type));
    }
}
