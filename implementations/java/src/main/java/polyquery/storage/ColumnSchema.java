package polyquery.storage;

import polyquery.types.DataType;

/** Name and type of a table column. */
public record ColumnSchema(String name, DataType type) {
}
