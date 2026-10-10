package polyquery.exec;

/** Execution model of a query (query option {@code mode}). */
public enum ExecMode {
    /** Row-at-a-time Volcano iterators: the unoptimized baseline. */
    ROW,
    /** Batches of column vectors with selection vectors; parallel scans and aggregations. */
    VECTORIZED
}
