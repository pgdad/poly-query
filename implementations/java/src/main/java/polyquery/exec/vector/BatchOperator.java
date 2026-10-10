package polyquery.exec.vector;

/** A batch-at-a-time physical operator (vectorized execution). */
public interface BatchOperator {
    void open();

    /** Next batch, or null when exhausted. The batch is reused by the following call. */
    Batch next();

    default void close() {
    }
}
