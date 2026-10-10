package polyquery.engine;

import java.util.List;
import polyquery.storage.ColumnSchema;
import polyquery.storage.Layout;
import polyquery.storage.Layouts;

/**
 * A validated {@code load} operation. Exactly one of {@code path}/{@code data} is non-null.
 *
 * @param layout     in-memory representation of the new table
 * @param dictionary dictionary encoding policy for STRING columns (column layout)
 */
public record LoadRequest(String table, String format, String path, String data, List<ColumnSchema> schema,
                          boolean header, char delimiter, boolean replace, Layout layout,
                          Layouts.Dictionary dictionary) {
    /** A load into the default (columnar, automatic dictionary) layout. */
    public LoadRequest(String table, String format, String path, String data, List<ColumnSchema> schema,
                       boolean header, char delimiter, boolean replace) {
        this(table, format, path, data, schema, header, delimiter, replace, Layout.COLUMN, Layouts.Dictionary.AUTO);
    }
}
