package polyquery.storage.pqcf;

import java.util.List;
import polyquery.index.IndexKind;
import polyquery.storage.ColumnSchema;

/**
 * Validated PQCF metadata (pqcf-v1.md §2).
 *
 * @param table    table name recorded by the writer
 * @param rowCount total rows
 * @param columns  schema
 * @param indexes  index definitions to recreate on open
 * @param groups   row groups in file order
 */
record FileMeta(String table, int rowCount, List<ColumnSchema> columns, List<IndexMeta> indexes,
                List<GroupMeta> groups) {

    /** One column chunk; {@code min}/{@code max} are runtime values or null when unknown. */
    record ChunkMeta(long offset, int length, long crc32, Encoding encoding, int nullCount, Object min, Object max) {
    }

    record GroupMeta(int rowCount, List<ChunkMeta> chunks) {
    }

    record IndexMeta(String name, int column, IndexKind kind) {
    }
}
