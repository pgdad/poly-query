package polyquery.storage;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;

/**
 * Name → table mapping. Tables are immutable; mutations replace map entries atomically so
 * readers holding a {@link Table} reference always see a consistent snapshot.
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

    /** Publishes a table; fails with ALREADY_EXISTS unless {@code replace}. */
    public synchronized void put(Table table, boolean replace) {
        String key = Table.key(table.name());
        if (!replace && tables.containsKey(key)) {
            throw PolyQueryException.of(ErrorCode.ALREADY_EXISTS, "table '%s' already exists", table.name());
        }
        tables.put(key, table);
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
}
