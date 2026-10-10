package polyquery.index;

import java.util.HashMap;
import java.util.Map;

/** Hash index: key → ascending row ids. Supports equality / IN lookups. */
public final class HashIndex implements IndexStructure {
    private final Map<Object, int[]> rows;

    private HashIndex(Map<Object, int[]> rows) {
        this.rows = rows;
    }

    /** Builds from {@code keys[i]} = key of row {@code i} (null for NULL rows, which are not indexed). */
    static HashIndex build(Object[] keys) {
        Map<Object, IntList> lists = new HashMap<>();
        for (int i = 0; i < keys.length; i++) {
            if (keys[i] != null) {
                lists.computeIfAbsent(keys[i], k -> new IntList(2)).add(i);
            }
        }
        Map<Object, int[]> out = new HashMap<>(lists.size() * 2);
        for (Map.Entry<Object, IntList> e : lists.entrySet()) {
            out.put(e.getKey(), e.getValue().toArray());
        }
        return new HashIndex(out);
    }

    @Override
    public boolean supports(KeyPredicate predicate) {
        return !(predicate instanceof KeyPredicate.Range);
    }

    @Override
    public int[] lookup(KeyPredicate predicate) {
        if (!(predicate instanceof KeyPredicate.Points p)) {
            if (predicate instanceof KeyPredicate.Empty) {
                return new int[0];
            }
            throw new IllegalArgumentException("hash indexes support equality lookups only");
        }
        if (p.keys().size() == 1) {
            int[] r = rows.get(p.keys().getFirst());
            return r == null ? new int[0] : r.clone();
        }
        IntList out = new IntList(16);
        for (Object k : p.keys()) {
            int[] r = rows.get(k);
            if (r != null) {
                out.addAll(r);
            }
        }
        return out.toSortedDistinct();
    }

    @Override
    public int distinctKeys() {
        return rows.size();
    }
}
