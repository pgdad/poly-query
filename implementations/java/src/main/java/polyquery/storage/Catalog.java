package polyquery.storage;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;
import polyquery.common.ErrorCode;
import polyquery.common.Names;
import polyquery.common.PolyQueryException;
import polyquery.index.Index;
import polyquery.index.IndexKind;

/**
 * Name → table mapping; each table snapshot carries its indexes. Tables are immutable and the
 * mapping itself is copy-on-write: mutations are serialized under the catalog lock and publish
 * a new immutable map with one volatile write, so they are atomic and linearizable, and a
 * {@link Snapshot} taken by a query sees exactly one catalog version for its whole execution
 * (concurrency.md §1). Index names are global.
 */
public final class Catalog {
    private volatile Map<String, Table> tables = Map.of();

    /** An immutable view of the catalog at one point in time. */
    public record Snapshot(Map<String, Table> tables) {
        public Table find(String name) {
            return tables.get(Table.key(name));
        }
    }

    public Snapshot snapshot() {
        return new Snapshot(tables);
    }

    public Table find(String name) {
        return tables.get(Table.key(name));
    }

    public int size() {
        return tables.size();
    }

    /** Publishes a modified copy of the mapping; callers hold the catalog lock. */
    private void mutate(Consumer<Map<String, Table>> change) {
        Map<String, Table> copy = new HashMap<>(tables);
        change.accept(copy);
        tables = Map.copyOf(copy);
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
        mutate(m -> m.put(Table.key(table.name()), table));
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
        if (!tables.containsKey(Table.key(name))) {
            throw PolyQueryException.of(ErrorCode.NOT_FOUND, "table '%s' does not exist", name);
        }
        mutate(m -> m.remove(Table.key(name)));
    }

    public synchronized void reset() {
        tables = Map.of();
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
                Table indexed = table.withIndexes(indexes);
                mutate(m -> m.put(Table.key(indexed.name()), indexed));
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
        Table updated = owner.withIndexes(remaining);
        mutate(m -> m.put(Table.key(updated.name()), updated));
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
