package polyquery.exec.vector;

/**
 * A batch of rows in columnar form: one {@link Vec} per slot of the producing operator's row
 * layout (null for slots nobody reads), {@code size} physical positions and a selection of the
 * {@code count} active positions in ascending order ({@code sel == null}: all positions
 * {@code 0 .. count-1} are active). Batches are owned and reused by their producer; a consumer
 * must be done with a batch before it asks for the next one.
 *
 * <p>{@code error} implements row-at-a-time error semantics: it is the error the row engine would
 * raise right after producing the active rows of this batch (e.g. a division by zero in a later
 * row). Consumers process the active rows first and raise the error only if they need further
 * rows — so a LIMIT that is satisfied earlier never sees it.
 */
public final class Batch {
    public Vec[] cols;
    public int size;
    public int[] sel;
    public int count;
    public RuntimeException error;

    public Batch(int width) {
        this.cols = new Vec[width];
    }

    /** Physical position of the k-th active row. */
    public int pos(int k) {
        return sel == null ? k : sel[k];
    }

    /**
     * Keeps only the first {@code k} active rows and records {@code e} as the error raised after
     * them (an error found by a later pipeline stage always precedes any recorded one).
     */
    void truncate(int k, RuntimeException e) {
        count = k;
        error = e;
    }

    /** Resets to an empty batch of {@code n} dense positions. */
    void reset(int n) {
        size = n;
        sel = null;
        count = n;
        error = null;
    }
}
