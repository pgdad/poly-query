package polyquery.storage;

/**
 * The stored rows of a table, partitioned into row groups (a single group for in-memory
 * tables, the file's row groups for PQCF-backed tables). Row ids are global: group {@code g}
 * holds rows {@code groupStart(g) .. groupStart(g) + groupSize(g) - 1}.
 *
 * <p>Implementations are immutable and safe for concurrent readers.
 */
public interface TableData {
    Layout layout();

    int rowCount();

    int groupCount();

    int groupStart(int group);

    int groupSize(int group);

    /** Values of column {@code column} for the rows of {@code group} (indexed from 0 within the group). */
    ColumnVector chunk(int group, int column);

    /**
     * Known bounds {@code [min, max]} (runtime values) of the non-null values of a chunk, or
     * null if unknown or the chunk has no non-null values. Used only for skipping row groups.
     */
    default Object[] chunkBounds(int group, int column) {
        return null;
    }

    /** Approximate heap footprint in bytes. */
    long estimatedBytes();
}
