package polyquery.exec;

import java.util.List;
import polyquery.storage.ColumnSchema;

/** Receives a query result incrementally: the column list first, then every row in order. */
public interface ResultSink {
    void columns(List<ColumnSchema> columns);

    void row(Object[] row);

    /** False if the sink only counts rows (they need not be materialized). */
    default boolean wantsRows() {
        return true;
    }
}
