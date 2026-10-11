package polyquery.index;

import java.util.Arrays;

/**
 * Ordered index: a sorted permutation of the non-null rows of a column (equivalent to the
 * leaf level of a B-tree), searched by binary search. Supports equality, IN and range lookups.
 */
public final class OrderedIndex implements IndexStructure {
    private final long[] longKeys;
    private final double[] doubleKeys;
    /** STRING or wide DECIMAL keys. */
    private final Object[] objectKeys;
    private final int[] rows;
    private final int distinct;

    private OrderedIndex(long[] longKeys, double[] doubleKeys, Object[] objectKeys, int[] rows) {
        this.longKeys = longKeys;
        this.doubleKeys = doubleKeys;
        this.objectKeys = objectKeys;
        this.rows = rows;
        int d = 0;
        for (int i = 0; i < rows.length; i++) {
            if (i == 0 || compareAt(i - 1, keyAt(i)) != 0) {
                d++;
            }
        }
        this.distinct = d;
    }

    /** Builds from {@code keys[i]} = key of row {@code i} (null for NULL rows, which are not indexed). */
    static OrderedIndex build(Object[] keys) {
        int n = 0;
        Object sample = null;
        for (Object k : keys) {
            if (k != null) {
                n++;
                sample = k;
            }
        }
        int[] perm = new int[n];
        int j = 0;
        for (int i = 0; i < keys.length; i++) {
            if (keys[i] != null) {
                perm[j++] = i;
            }
        }
        // Stable sort by key keeps equal keys in ascending row order.
        IntSort.sort(perm, (a, b) -> KeyDomain.compare(keys[a], keys[b]));
        long[] longs = null;
        double[] doubles = null;
        Object[] objects = null;
        if (sample instanceof Long) {
            longs = new long[n];
            for (int i = 0; i < n; i++) {
                longs[i] = (Long) keys[perm[i]];
            }
        } else if (sample instanceof Double) {
            doubles = new double[n];
            for (int i = 0; i < n; i++) {
                doubles[i] = (Double) keys[perm[i]];
            }
        } else {
            objects = new Object[n];
            for (int i = 0; i < n; i++) {
                objects[i] = keys[perm[i]];
            }
        }
        return new OrderedIndex(longs, doubles, objects, perm);
    }

    private Object keyAt(int i) {
        if (longKeys != null) {
            return longKeys[i];
        }
        if (doubleKeys != null) {
            return doubleKeys[i];
        }
        return objectKeys[i];
    }

    /** Compares the key at position {@code i} with {@code key}. */
    private int compareAt(int i, Object key) {
        if (longKeys != null) {
            return Long.compare(longKeys[i], (Long) key);
        }
        if (doubleKeys != null) {
            return Double.compare(doubleKeys[i], (Double) key);
        }
        return KeyDomain.compare(objectKeys[i], key);
    }

    /** First position whose key is {@code >= key} (or {@code > key} if {@code strict}). */
    private int lowerBound(Object key, boolean strict) {
        int lo = 0;
        int hi = rows.length;
        while (lo < hi) {
            int mid = (lo + hi) >>> 1;
            int c = compareAt(mid, key);
            if (c < 0 || (strict && c == 0)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    @Override
    public boolean supports(KeyPredicate predicate) {
        return true;
    }

    @Override
    public int[] lookup(KeyPredicate predicate) {
        IntList out = new IntList(16);
        switch (predicate) {
            case KeyPredicate.Empty e -> {
                return new int[0];
            }
            case KeyPredicate.Points p -> {
                for (Object k : p.keys()) {
                    collect(lowerBound(k, false), lowerBound(k, true), out);
                }
            }
            case KeyPredicate.Range r -> {
                int from = r.lower() == null ? 0 : lowerBound(r.lower(), !r.lowerInclusive());
                int to = r.upper() == null ? rows.length : lowerBound(r.upper(), r.upperInclusive());
                collect(from, to, out);
            }
        }
        int[] result = out.toArray();
        Arrays.sort(result);
        return result;
    }

    private void collect(int from, int to, IntList out) {
        for (int i = from; i < to; i++) {
            out.add(rows[i]);
        }
    }

    @Override
    public int distinctKeys() {
        return distinct;
    }
}
