package polyquery.exec;

import java.util.List;
import polyquery.storage.ColumnSchema;

/** Materialized query result; {@code rows} is null when only the count was requested. */
public record QueryResult(List<ColumnSchema> columns, List<Object[]> rows, long rowCount) {
}
