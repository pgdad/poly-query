package polyquery.index;

import polyquery.storage.ColumnVector;
import polyquery.storage.TableData;
import polyquery.types.DataType;

/**
 * A single-column secondary index of one table snapshot.
 *
 * @param name      catalog-wide index name (as created)
 * @param column    column position in the table
 * @param kind      HASH or BTREE
 * @param structure lookup structure over the table's row ids
 */
public record Index(String name, int column, IndexKind kind, IndexStructure structure) {
    /** Builds an index over column {@code column} (of type {@code type}) of {@code data}. */
    public static Index build(String name, TableData data, int column, DataType type, IndexKind kind) {
        Object[] keys = new Object[data.rowCount()];
        for (int g = 0; g < data.groupCount(); g++) {
            ColumnVector v = data.chunk(g, column);
            int start = data.groupStart(g);
            for (int i = 0; i < data.groupSize(g); i++) {
                Object x = v.get(i);
                if (x != null) {
                    keys[start + i] = KeyDomain.key(x, type);
                }
            }
        }
        IndexStructure s = kind == IndexKind.HASH ? HashIndex.build(keys) : OrderedIndex.build(keys);
        return new Index(name, column, kind, s);
    }
}
