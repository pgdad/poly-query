package polyquery.exec.vector;

import java.util.List;
import polyquery.storage.ColumnSchema;

/**
 * Growable columnar storage of materialized rows (one vector per slot, plain representation),
 * used by blocking operators (hash join build side, sort).
 */
final class ColumnStore {
    private final List<ColumnSchema> schema;
    private final Vec[] cols;
    private int rows;
    private int capacity;

    ColumnStore(List<ColumnSchema> schema) {
        this.schema = schema;
        this.capacity = 64;
        this.cols = new Vec[schema.size()];
        for (int c = 0; c < cols.length; c++) {
            cols[c] = new Vec(schema.get(c).type(), capacity);
            cols[c].nullMask(capacity);
        }
    }

    int rows() {
        return rows;
    }

    Vec column(int slot) {
        return cols[slot];
    }

    /** Appends the rows at positions {@code keep[0..m)} of {@code b}; returns the first new row index. */
    int append(Batch b, int[] keep, int m) {
        int start = rows;
        int need = rows + m;
        if (need > capacity) {
            capacity = Math.max(need, capacity * 2);
            for (Vec v : cols) {
                v.grow(capacity);
            }
        }
        for (int c = 0; c < cols.length; c++) {
            Vec dst = cols[c];
            Vec src = b.cols[c];
            if (src == null) {
                for (int k = 0; k < m; k++) {
                    dst.nulls[start + k] = true; // a slot nobody reads
                }
            } else {
                gather(src, keep, m, dst, start);
            }
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

    /** A new store with rows {@code perm[0..count)} of this one, in that order. */
    ColumnStore select(int[] perm, int count) {
        ColumnStore out = new ColumnStore(schema);
        if (count > out.capacity) {
            out.capacity = count;
            for (Vec v : out.cols) {
                v.grow(count);
            }
        }
        for (int c = 0; c < cols.length; c++) {
            gather(cols[c], perm, 0, count, out.cols[c], 0);
        }
        out.rows = count;
        return out;
    }

    /** {@code dst[at + k] = src[idx[k]]} for k in [0, m) (null mask of dst prepared). */
    static void gather(Vec src, int[] idx, int m, Vec dst, int at) {
        gather(src, idx, 0, m, dst, at);
    }

    /** {@code dst[at + k] = src[idx[from + k]]} for k in [0, m) (null mask of dst prepared). */
    static void gather(Vec src, int[] idx, int from, int m, Vec dst, int at) {
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
                String[] dict = src.dict;
                int[] s = src.codes;
                Object[] d = dst.objects;
                for (int k = 0; k < m; k++) {
                    d[at + k] = dn[at + k] ? null : dict[s[idx[from + k]]];
                }
            }
        }
    }
}
