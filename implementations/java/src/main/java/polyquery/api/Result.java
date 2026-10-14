package polyquery.api;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.AbstractList;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import polyquery.types.DataType;

/**
 * The complete, immutable result of a query: columns (names and types) and rows. Values are
 * typed Java objects as listed on {@link ColumnType.Kind}; SQL NULL is {@code null}. Rows and
 * columns are numbered from 0.
 *
 * <p>A result is independent of its {@link Database}: it stays readable after the instance
 * changes or is closed, and may be read from several threads.
 */
public final class Result {
    private final List<Column> columns;
    private final DataType[] types;
    private final List<Object[]> rows;

    Result(List<Column> columns, DataType[] types, List<Object[]> rows) {
        this.columns = List.copyOf(columns);
        this.types = types;
        this.rows = rows;
    }

    /** The result's columns in order. */
    public List<Column> columns() {
        return columns;
    }

    /** The column names in order. */
    public List<String> columnNames() {
        return columns.stream().map(Column::name).toList();
    }

    /** The column types in order. */
    public List<ColumnType> columnTypes() {
        return columns.stream().map(Column::type).toList();
    }

    public int columnCount() {
        return columns.size();
    }

    /** The number of rows. */
    public int rowCount() {
        return rows.size();
    }

    /**
     * The index of the first column named {@code name} (ASCII case-insensitive), or -1.
     */
    public int columnIndex(String name) {
        for (int i = 0; i < columns.size(); i++) {
            if (columns.get(i).name().equalsIgnoreCase(name)) {
                return i;
            }
        }
        return -1;
    }

    /** The value at ({@code row}, {@code column}): a Java object of the column's kind, or {@code null}. */
    public Object get(int row, int column) {
        return ValueMapping.toApi(rows.get(row)[column], types[column]);
    }

    /** True if the value at ({@code row}, {@code column}) is SQL NULL. */
    public boolean isNull(int row, int column) {
        return rows.get(row)[column] == null;
    }

    /** An INT64 value, or {@code null}. */
    public Long getLong(int row, int column) {
        return typed(row, column, ColumnType.Kind.INT64, Long.class);
    }

    /** A DECIMAL value with the column's scale, or {@code null}. */
    public BigDecimal getDecimal(int row, int column) {
        return typed(row, column, ColumnType.Kind.DECIMAL, BigDecimal.class);
    }

    /** A FLOAT64 value, or {@code null}. */
    public Double getDouble(int row, int column) {
        return typed(row, column, ColumnType.Kind.FLOAT64, Double.class);
    }

    /** A STRING value, or {@code null}. */
    public String getString(int row, int column) {
        return typed(row, column, ColumnType.Kind.STRING, String.class);
    }

    /** A BOOLEAN value, or {@code null}. */
    public Boolean getBoolean(int row, int column) {
        return typed(row, column, ColumnType.Kind.BOOLEAN, Boolean.class);
    }

    /** A DATE value, or {@code null}. */
    public LocalDate getDate(int row, int column) {
        return typed(row, column, ColumnType.Kind.DATE, LocalDate.class);
    }

    /** A TIMESTAMP value, or {@code null}. */
    public LocalDateTime getTimestamp(int row, int column) {
        return typed(row, column, ColumnType.Kind.TIMESTAMP, LocalDateTime.class);
    }

    private <T> T typed(int row, int column, ColumnType.Kind kind, Class<T> cls) {
        ColumnType type = columns.get(column).type();
        if (type.kind() != kind) {
            throw new IllegalArgumentException("column " + column + " ('" + columns.get(column).name() + "') is "
                    + type + ", not " + kind);
        }
        return cls.cast(get(row, column));
    }

    /** Row {@code row} as an unmodifiable list of values (which may contain {@code null}). */
    public List<Object> row(int row) {
        Object[] raw = rows.get(row);
        List<Object> out = new ArrayList<>(raw.length);
        for (int c = 0; c < raw.length; c++) {
            out.add(ValueMapping.toApi(raw[c], types[c]));
        }
        return Collections.unmodifiableList(out);
    }

    /** All rows, converted on access (an unmodifiable view). */
    public List<List<Object>> rows() {
        return new AbstractList<>() {
            @Override
            public List<Object> get(int index) {
                return row(index);
            }

            @Override
            public int size() {
                return rows.size();
            }
        };
    }
}
