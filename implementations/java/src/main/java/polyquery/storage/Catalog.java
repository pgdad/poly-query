package polyquery.storage;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import polyquery.common.ErrorCode;
import polyquery.common.Names;
import polyquery.common.PolyQueryException;
import polyquery.index.Index;
import polyquery.index.IndexKind;

/**
 * Name → table mapping; each table snapshot carries its indexes. Tables are immutable;
 * mutations replace map entries atomically (under the catalog lock) so readers holding a
 * {@link Table} reference always see a consistent snapshot. Index names are global.
 */
public final class Catalog {
    private final Map<String, Table> tables = new ConcurrentHashMap<>();

    public Table find(String name) {
        return tables.get(Table.key(name));
    }

    public Table require(String name) {
        Table t = find(name);
        if (t == null) {
            throw PolyQueryException.of(ErrorCode.NOT_FOUND, "table '%s' does not exist", name);
        }
        return t;
    }

    /**
     * Publishes a table together with the indexes it carries; fails with ALREADY_EXISTS unless
     * {@code replace}, or if one of its index names is used by another table. A replaced
     * table's indexes are dropped with it.
     */
    public synchronized void put(Table table, boolean replace) {
        checkAvailable(table.name(), indexNames(table.indexes()), replace);
        tables.put(Table.key(table.name()), table);
    }

    /**
     * Fails like {@link #put} would for a table named {@code name} carrying indexes named
     * {@code indexNames}; lets callers fail before doing expensive work.
     */
    public synchronized void checkAvailable(String name, Collection<String> indexNames, boolean replace) {
        String key = Table.key(name);
        if (!replace && tables.containsKey(key)) {
            throw PolyQueryException.of(ErrorCode.ALREADY_EXISTS, "table '%s' already exists", name);
        }
        for (String idx : indexNames) {
            Table owner = indexOwner(idx);
            if (owner != null && !Table.key(owner.name()).equals(key)) {
                throw PolyQueryException.of(ErrorCode.ALREADY_EXISTS, "index '%s' already exists", idx);
            }
        }
    }

    public synchronized void drop(String name) {
        if (tables.remove(Table.key(name)) == null) {
            throw PolyQueryException.of(ErrorCode.NOT_FOUND, "table '%s' does not exist", name);
        }
    }

    public synchronized void reset() {
        tables.clear();
    }

    /** All tables sorted by name, case-insensitively. */
    public List<Table> list() {
        List<Table> out = new ArrayList<>(tables.values());
        out.sort(Comparator.comparing((Table t) -> Table.key(t.name())).thenComparing(Table::name));
        return out;
    }

    // ---------------------------------------------------------------- indexes

    /** {@code CREATE INDEX} (semantics.md §14). The index is built outside the catalog lock. */
    public void createIndex(String name, boolean ifNotExists, String tableName, String columnName, IndexKind kind) {
        while (true) {
            Table table = find(tableName);
            if (table == null) {
                throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "table '%s' does not exist", tableName);
            }
            int column = table.findColumn(columnName);
            if (column < 0) {
                throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "column '%s' does not exist in table '%s'",
                        columnName, table.name());
            }
            if (indexExists(name, ifNotExists)) {
                return;
            }
            Index index = Index.build(name, table.data(), column, table.columnType(column), kind);
            synchronized (this) {
                if (indexExists(name, ifNotExists)) {
                    return;
                }
                if (tables.get(Table.key(table.name())) != table) {
                    continue; // the table changed while the index was built: start over
                }
                List<Index> indexes = new ArrayList<>(table.indexes());
                indexes.add(index);
                tables.put(Table.key(table.name()), table.withIndexes(indexes));
                return;
            }
        }
    }

    private synchronized boolean indexExists(String name, boolean ifNotExists) {
        if (indexOwner(name) == null) {
            return false;
        }
        if (ifNotExists) {
            return true;
        }
        throw PolyQueryException.of(ErrorCode.ALREADY_EXISTS, "index '%s' already exists", name);
    }

    /** {@code DROP INDEX}: NOT_FOUND for an unknown name unless {@code ifExists}. */
    public synchronized void dropIndex(String name, boolean ifExists) {
        Table owner = indexOwner(name);
        if (owner == null) {
            if (ifExists) {
                return;
            }
            throw PolyQueryException.of(ErrorCode.NOT_FOUND, "index '%s' does not exist", name);
        }
        List<Index> remaining = new ArrayList<>();
        for (Index i : owner.indexes()) {
            if (!Names.equal(i.name(), name)) {
                remaining.add(i);
            }
        }
        tables.put(Table.key(owner.name()), owner.withIndexes(remaining));
    }

    private Table indexOwner(String indexName) {
        for (Table t : tables.values()) {
            for (Index i : t.indexes()) {
                if (Names.equal(i.name(), indexName)) {
                    return t;
                }
            }
        }
        return null;
    }

    private static List<String> indexNames(List<Index> indexes) {
        List<String> out = new ArrayList<>();
        for (Index i : indexes) {
            out.add(i.name());
        }
        return out;
    }
}
