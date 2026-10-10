package polyquery.exec;

/** Row-at-a-time (Volcano) physical operator. */
public interface Operator {
    void open();

    /** Next row, or {@code null} when exhausted. */
    Object[] next();

    default void close() {
    }
}
