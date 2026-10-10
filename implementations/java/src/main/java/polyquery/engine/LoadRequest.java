package polyquery.engine;

import java.util.List;
import polyquery.storage.ColumnSchema;

/** A validated {@code load} operation. Exactly one of {@code path}/{@code data} is non-null. */
public record LoadRequest(String table, String format, String path, String data, List<ColumnSchema> schema,
                          boolean header, char delimiter, boolean replace) {
}
