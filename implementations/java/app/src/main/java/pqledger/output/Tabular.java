package pqledger.output;

import java.util.List;
import polyquery.api.Column;
import polyquery.api.Result;

/**
 * A result to print: typed columns and rows of typed values (the Java classes of the embedding
 * API, {@code null} for NULL).
 */
public record Tabular(List<Column> columns, List<List<Object>> rows) {
    public Tabular {
        columns = List.copyOf(columns);
        rows = List.copyOf(rows);
    }

    public static Tabular of(Result result) {
        return new Tabular(result.columns(), result.rows());
    }
}
