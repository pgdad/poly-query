package polyquery.exec.vector;

import java.util.List;
import polyquery.storage.ColumnSchema;

/**
 * Growable columnar storage of materialized rows (one vector per slot), used by blocking
 * operators (hash join build side, sort). A STRING column stays dictionary-encoded as long as
 * all its input batches share one dictionary (the usual case for in-memory tables).
 */
final class ColumnStore {
    private final List<ColumnSchema> schema;
    private final Vec[] cols;
    private final boolean[] populated;
    private int rows;
    private int capacity;

    ColumnStore(List<ColumnSchema> schema) {
        this(schema, 0);
    }

    /** @param expectedRows rows expected (an exact count avoids regrowing; 0 = unknown) */
    ColumnStore(List<ColumnSchema> schema, int expectedRows) {
        this.schema = schema;
        this.capacity = Math.max(64, expectedRows);
        this.cols = new Vec[schema.size()];
        this.populated = new boolean[cols.length];
    }

    /** The vector of slot c, allocated when the slot is first filled. */
    private Vec allocate(int c) {
        Vec v = cols[c];
        if (v == null) {
            v = new Vec(schema.get(c).type(), capacity);
            v.nullMask(capacity);
            java.util.Arrays.fill(v.nulls, 0, rows, true);
            v.hasNulls = rows > 0; // set once a NULL is stored
            cols[c] = v;
            populated[c] = true;
        }
        return v;
    }

    int rows() {
        return rows;
    }

    /** The stored values of a slot, or null if the input never filled it (nobody reads it). */
    Vec column(int slot) {
        return populated[slot] ? cols[slot] : null;
    }

    /** Appends the rows at positions {@code keep[0..m)} of {@code b}; returns the first new row index. */
    int append(Batch b, int[] keep, int m) {
        int start = rows;
        int need = rows + m;
        if (need > capacity) {
            capacity = Math.max(need, capacity * 2);
            for (Vec v : cols) {
                if (v != null) {
                    v.grow(capacity);
                }
            }
        }
        for (int c = 0; c < cols.length; c++) {
            Vec src = b.cols[c];
            if (src == null) {
                continue; // a slot nobody reads
            }
            Vec dst = allocate(c);
            if (dst.kind == Vec.Kind.DICT && (src.kind != Vec.Kind.DICT || src.dict != dst.dict)) {
                decode(dst, start);
            } else if (start == 0 && src.kind == Vec.Kind.DICT && dst.kind == Vec.Kind.OBJECT) {
                dst.toDict(src.dict, capacity);
            }
            boolean hadNulls = dst.hasNulls;
            gather(src, keep, m, dst, start);
            dst.hasNulls = hadNulls || src.hasNulls && anyTrue(dst.nulls, start, m);
        }
        rows = need;
        return start;
    }

    /**
     * Heap estimate of the rows at positions {@code keep[0..m)} of {@code b} when materialized,
     * computed like the row engine's estimate of row arrays (for the query memory budget).
     */
    static long estimate(Batch b, int[] keep, int m) {
        long total = (long) m * (16 + 8L * b.cols.length);
        for (Vec v : b.cols) {
            if (v == null) {
                continue;
            }
            for (int k = 0; k < m; k++) {
                int i = keep[k];
                if (v.isNull(i)) {
                    continue;
                }
                total += switch (v.kind) {
                    case OBJECT -> 40 + ((String) v.objects[i]).length();
                    case DICT -> 40 + v.dict[v.codes[i]].length();
                    default -> 16;
                };
            }
        }
        return total;
    }

    private static boolean anyTrue(boolean[] a, int from, int n) {
        for (int i = from; i < from + n; i++) {
            if (a[i]) {
                return true;
            }
        }
        return false;
    }

    /** Switches a dictionary column to plain strings (rows {@code 0..n-1} decoded). */
    private void decode(Vec v, int n) {
        String[] dict = v.dict;
        int[] codes = v.codes;
        v.toObjects(capacity);
        for (int i = 0; i < n; i++) {
            v.objects[i] = v.nulls[i] ? null : dict[codes[i]];
        }
    }

    /** A new store with rows {@code perm[0..count)} of this one, in that order. */
    ColumnStore select(int[] perm, int count) {
        ColumnStore out = new ColumnStore(schema, count);
        for (int c = 0; c < cols.length; c++) {
            if (!populated[c]) {
                continue;
            }
            out.allocate(c);
            if (cols[c].kind == Vec.Kind.DICT) {
                out.cols[c].toDict(cols[c].dict, out.capacity);
            }
            gather(cols[c], perm, 0, count, out.cols[c], 0);
            out.cols[c].hasNulls = cols[c].hasNulls;
        }
        out.rows = count;
        return out;
    }

    /**
     * {@code dst[k] = src[idx[k]]} for k in [0, m), NULL where {@code idx[k] < 0} (LEFT JOIN
     * padding); {@code src} is not dictionary-encoded, the null mask of dst is prepared.
     */
    static void gatherOrNull(Vec src, int[] idx, int m, Vec dst) {
        boolean[] dn = dst.nulls;
        for (int k = 0; k < m; k++) {
            int r = idx[k];
            dn[k] = r < 0 || src.isNull(r);
        }
        switch (src.kind) {
            case LONG -> {
                long[] s = src.longs;
                long[] d = dst.longs;
                for (int k = 0; k < m; k++) {
                    int r = idx[k];
                    d[k] = r < 0 ? 0 : s[r];
                }
            }
            case DOUBLE -> {
                double[] s = src.doubles;
                double[] d = dst.doubles;
                for (int k = 0; k < m; k++) {
                    int r = idx[k];
                    d[k] = r < 0 ? 0 : s[r];
                }
            }
            case OBJECT -> {
                Object[] s = src.objects;
                Object[] d = dst.objects;
                for (int k = 0; k < m; k++) {
                    int r = idx[k];
                    d[k] = r < 0 ? null : s[r];
                }
            }
            case DICT -> throw new IllegalStateException("dictionary source");
        }
    }

    /** {@code dst[at + k] = src[idx[k]]} for k in [0, m) (null mask of dst prepared). */
    static void gather(Vec src, int[] idx, int m, Vec dst, int at) {
        gather(src, idx, 0, m, dst, at);
    }

    /**
     * {@code dst[at + k] = src[idx[from + k]]} for k in [0, m) (null mask of dst prepared). A
     * dictionary source is copied as codes when {@code dst} uses the same dictionary or when
     * {@code at == 0} (dst then switches to that dictionary), else decoded.
     */
    static void gather(Vec src, int[] idx, int from, int m, Vec dst, int at) {
        if (src.kind == Vec.Kind.DICT && at == 0 && (dst.kind != Vec.Kind.DICT || dst.dict != src.dict)) {
            dst.toDict(src.dict, Math.max(m, dst.nulls.length));
        } else if (src.kind != Vec.Kind.DICT && dst.kind == Vec.Kind.DICT) {
            if (at != 0) {
                throw new IllegalStateException("plain strings appended to a dictionary column");
            }
            dst.toObjects(Math.max(m, dst.nulls.length));
        }
        boolean[] dn = dst.nulls;
        if (src.hasNulls) {
            boolean[] sn = src.nulls;
            for (int k = 0; k < m; k++) {
                dn[at + k] = sn[idx[from + k]];
            }
        } else {
            java.util.Arrays.fill(dn, at, at + m, false);
        }
        switch (src.kind) {
            case LONG -> {
                long[] s = src.longs;
                long[] d = dst.longs;
                for (int k = 0; k < m; k++) {
                    d[at + k] = s[idx[from + k]];
                }
            }
            case DOUBLE -> {
                double[] s = src.doubles;
                double[] d = dst.doubles;
                for (int k = 0; k < m; k++) {
                    d[at + k] = s[idx[from + k]];
                }
            }
            case OBJECT -> {
                Object[] s = src.objects;
                Object[] d = dst.objects;
                for (int k = 0; k < m; k++) {
                    d[at + k] = s[idx[from + k]];
                }
            }
            case DICT -> {
                int[] s = src.codes;
                if (dst.kind == Vec.Kind.DICT && dst.dict == src.dict) {
                    int[] d = dst.codes;
                    for (int k = 0; k < m; k++) {
                        d[at + k] = s[idx[from + k]];
                    }
                    return;
                }
                if (dst.kind == Vec.Kind.DICT) {
                    throw new IllegalStateException("dictionary mismatch in gather");
                }
                String[] dict = src.dict;
                Object[] d = dst.objects;
                for (int k = 0; k < m; k++) {
                    d[at + k] = dn[at + k] ? null : dict[s[idx[from + k]]];
                }
            }
        }
    }
}
