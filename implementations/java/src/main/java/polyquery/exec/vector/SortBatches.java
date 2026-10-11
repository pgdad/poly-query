package polyquery.exec.vector;

import java.math.BigInteger;
import java.util.List;
import polyquery.exec.ExecContext;
import polyquery.plan.SortKey;
import polyquery.storage.ColumnSchema;
import polyquery.types.Values;

/**
 * Sorting over a column store: ORDER BY (full sort) and ORDER BY … LIMIT (top-N). Rows are
 * ordered by a stable sort of row indices — an LSD radix sort on an order-preserving 64-bit key
 * of the first sort key, refined by a merge sort with typed comparisons within runs of equal
 * radix keys — so ties keep their input order, exactly like the row engine's stable sort.
 */
final class SortBatches {
    private static final int INSERTION_RUN = 24;

    private SortBatches() {
    }

    /** Comparison of two rows of a store. */
    interface RowOrder {
        int compare(int a, int b);
    }

    /** Characters of a string covered by {@link #prefix} and {@link #prefix2} together. */
    private static final int PREFIX_CHARS = 8;

    /**
     * An unsigned 64-bit prefix of a string consistent with code point order: the first four
     * UTF-16 units mapped like {@link Values#compareStrings} (surrogates above the BMP), zero
     * padded. Different prefixes order like the strings; equal prefixes need a full comparison.
     */
    static long prefix(String s) {
        return prefix(s, 0);
    }

    /** Like {@link #prefix}, for UTF-16 units 4..7 (zero padded). */
    static long prefix2(String s) {
        return prefix(s, 4);
    }

    private static long prefix(String s, int from) {
        long p = 0;
        int n = Math.min(from + 4, s.length());
        for (int i = from; i < from + 4; i++) {
            int c = 0;
            if (i < n) {
                c = s.charAt(i);
                if (c >= 0xD800) {
                    c = c >= 0xE000 ? c - 0x800 : c + 0x2000;
                }
            }
            p = (p << 16) | c;
        }
        return p;
    }

    /**
     * Lexicographic order of rows by the sort keys (NULL placement independent of direction),
     * starting at key {@code from} (the keys before it are known to be equal).
     *
     * <p>Every key is turned into an unsigned 64-bit key per row that orders like the values in
     * the key's direction ({@link #sortKey}: exact for numbers, a prefix for strings and wide
     * DECIMALs), so the comparison is one loop over long arrays whatever the key types — no
     * per-comparison dispatch on the column kind, and nothing a JIT type profile could specialize
     * for one query's key types only. Strings also get a second 4-unit prefix and their length:
     * with equal 8-unit prefixes, a string of at most 8 units orders by length alone, so the
     * (scattered) string objects are only read when both strings are longer than 8 units.
     */
    static RowOrder order(ColumnStore store, List<SortKey> keys, int from) {
        int n = keys.size() - from;
        long[][] norm = new long[n][];
        long[][] norm2 = new long[n][];
        int[][] lengths = new int[n][];
        boolean[][] nulls = new boolean[n][];
        boolean[] nullsFirst = new boolean[n];
        boolean[] desc = new boolean[n];
        Vec[] cols = new Vec[n];
        int rows = store.rows();
        for (int j = 0; j < n; j++) {
            SortKey key = keys.get(from + j);
            Vec v = store.column(key.column());
            cols[j] = v;
            desc[j] = key.descending();
            nullsFirst[j] = key.nullsFirst();
            nulls[j] = v.hasNulls ? v.nulls : null;
            long flip = desc[j] ? -1L : 0L;
            long[] k = new long[rows];
            if ((v.kind == Vec.Kind.OBJECT || v.kind == Vec.Kind.DICT) && !v.type.isWideDecimal()) {
                long[] k2 = new long[rows];
                int[] len = new int[rows];
                for (int i = 0; i < rows; i++) {
                    if (!v.isNull(i)) {
                        String str = v.string(i);
                        k[i] = prefix(str) ^ flip;
                        k2[i] = prefix2(str) ^ flip;
                        len[i] = str.length();
                    }
                }
                norm2[j] = k2;
                lengths[j] = len;
            } else {
                for (int i = 0; i < rows; i++) {
                    if (!v.isNull(i)) {
                        k[i] = sortKey(v, i) ^ flip;
                    }
                }
            }
            norm[j] = k;
        }
        return (a, b) -> {
            for (int j = 0; j < n; j++) {
                boolean[] m = nulls[j];
                if (m != null && (m[a] || m[b])) {
                    if (m[a] && m[b]) {
                        continue;
                    }
                    return m[a] == nullsFirst[j] ? -1 : 1;
                }
                long x = norm[j][a];
                long y = norm[j][b];
                if (x != y) {
                    return Long.compareUnsigned(x, y);
                }
                Vec v = cols[j];
                int c;
                long[] k2 = norm2[j];
                if (k2 != null) {
                    x = k2[a];
                    y = k2[b];
                    if (x != y) {
                        return Long.compareUnsigned(x, y);
                    }
                    int la = lengths[j][a];
                    int lb = lengths[j][b];
                    c = Math.min(la, lb) <= PREFIX_CHARS ? Integer.compare(la, lb)
                            : Values.compareStrings(v.string(a), v.string(b));
                } else if (v.kind == Vec.Kind.OBJECT) {
                    c = ((BigInteger) v.objects[a]).compareTo((BigInteger) v.objects[b]);
                } else {
                    continue; // numbers: the 64-bit keys are the values
                }
                if (c != 0) {
                    return desc[j] ? -c : c;
                }
            }
            return 0;
        };
    }

    /**
     * Row indices {@code 0..rows-1} of {@code store} in sort order (stable): a radix sort on a
     * 64-bit key of the first sort key (the value for numbers, a prefix for strings), then a merge
     * sort with full comparisons within each run of equal radix keys (if needed).
     */
    static int[] sort(ColumnStore store, List<SortKey> keys, ExecContext ctx) {
        int n = store.rows();
        if (n == 0) {
            return new int[0];
        }
        SortKey first = keys.getFirst();
        Vec v = store.column(first.column());
        long[] sortedKeys = new long[n];
        int[] idx = radix(v, n, first, sortedKeys, ctx);
        if (keys.size() == 1 && (v.kind == Vec.Kind.LONG || v.kind == Vec.Kind.DOUBLE)) {
            return idx; // the radix key is the whole sort key
        }
        // within a run of equal radix keys a numeric first key is equal, so the comparison starts after it
        RowOrder order = order(store, keys, v.kind == Vec.Kind.LONG || v.kind == Vec.Kind.DOUBLE ? 1 : 0);
        int[] tmp = new int[n];
        int i = 0;
        while (i < n) {
            int j = i + 1;
            boolean isNull = v.isNull(idx[i]);
            while (j < n && v.isNull(idx[j]) == isNull && (isNull || sortedKeys[j] == sortedKeys[i])) {
                j++;
            }
            if (j - i > 1) {
                mergeSort(idx, tmp, i, j, order, ctx);
            }
            i = j;
        }
        return idx;
    }

    /**
     * An unsigned 64-bit key whose order is the value order (doubles: -0.0 equals 0.0); for
     * strings a prefix, for wide DECIMALs the high 64 bits of the 128-bit value (equal keys need
     * a full comparison).
     */
    private static long sortKey(Vec v, int i) {
        return switch (v.kind) {
            case LONG -> v.longs[i] ^ Long.MIN_VALUE;
            case DOUBLE -> {
                double d = v.doubles[i];
                long bits = Double.doubleToLongBits(d == 0.0 ? 0.0 : d);
                yield bits < 0 ? ~bits : bits ^ Long.MIN_VALUE;
            }
            default -> v.type.isWideDecimal() ? ((BigInteger) v.objects[i]).shiftRight(64).longValue() ^ Long.MIN_VALUE
                    : prefix(v.string(i));
        };
    }

    /**
     * Stable LSD radix sort (8 bits per pass, constant bytes skipped) of rows by the 64-bit key
     * of one sort key; NULLs first or last. {@code sortedKeys[r]} receives the key of the r-th
     * row of the result (non-NULL rows only).
     */
    private static int[] radix(Vec v, int n, SortKey key, long[] sortedKeys, ExecContext ctx) {
        int nullCount = 0;
        for (int i = 0; i < n; i++) {
            if (v.isNull(i)) {
                nullCount++;
            }
        }
        int m = n - nullCount;
        long[] keys = new long[m];
        int[] ids = new int[m];
        int[] out = new int[n];
        int nullAt = key.nullsFirst() ? 0 : m;
        int k = 0;
        for (int i = 0; i < n; i++) {
            if (v.isNull(i)) {
                out[nullAt++] = i;
            } else {
                long s = sortKey(v, i);
                keys[k] = key.descending() ? ~s : s;
                ids[k++] = i;
            }
        }
        long[] tk = new long[m];
        int[] ti = new int[m];
        int[] count = new int[257];
        for (int shift = 0; shift < 64; shift += 8) {
            java.util.Arrays.fill(count, 0);
            for (int i = 0; i < m; i++) {
                count[(int) ((keys[i] >>> shift) & 0xFF) + 1]++;
            }
            boolean trivial = false;
            for (int b = 1; b <= 256; b++) {
                if (count[b] == m) {
                    trivial = true; // every key has this byte: nothing to reorder
                    break;
                }
            }
            if (trivial) {
                continue;
            }
            for (int b = 0; b < 256; b++) {
                count[b + 1] += count[b];
            }
            for (int i = 0; i < m; i++) {
                int b = (int) ((keys[i] >>> shift) & 0xFF);
                int at = count[b]++;
                tk[at] = keys[i];
                ti[at] = ids[i];
            }
            long[] t1 = keys;
            keys = tk;
            tk = t1;
            int[] t2 = ids;
            ids = ti;
            ti = t2;
            ctx.checkNow();
        }
        int base = key.nullsFirst() ? nullCount : 0;
        System.arraycopy(ids, 0, out, base, m);
        System.arraycopy(keys, 0, sortedKeys, base, m);
        return out;
    }

    /** Stable top-down merge sort of {@code a[from, to)} (insertion sort for short runs). */
    private static void mergeSort(int[] a, int[] tmp, int from, int to, RowOrder order, ExecContext ctx) {
        int n = to - from;
        if (n <= INSERTION_RUN) {
            for (int i = from + 1; i < to; i++) {
                int x = a[i];
                int j = i - 1;
                while (j >= from && order.compare(a[j], x) > 0) {
                    a[j + 1] = a[j];
                    j--;
                }
                a[j + 1] = x;
            }
            return;
        }
        int mid = (from + to) >>> 1;
        mergeSort(a, tmp, from, mid, order, ctx);
        mergeSort(a, tmp, mid, to, order, ctx);
        if (order.compare(a[mid - 1], a[mid]) <= 0) {
            return; // already in order
        }
        if (n > 65_536) {
            ctx.checkNow();
        }
        System.arraycopy(a, from, tmp, from, n);
        int i = from;
        int j = mid;
        int k = from;
        while (i < mid && j < to) {
            a[k++] = order.compare(tmp[j], tmp[i]) < 0 ? tmp[j++] : tmp[i++];
        }
        while (i < mid) {
            a[k++] = tmp[i++];
        }
        while (j < to) {
            a[k++] = tmp[j++];
        }
    }

    /**
     * Blocking sort of the input; with {@code limit >= 0} a top-N that keeps only the best
     * {@code offset + limit} rows (re-sorting and truncating the store whenever it doubles) and
     * returns rows {@code offset .. offset+limit-1}.
     */
    static final class Sort implements BatchOperator {
        private final BatchOperator input;
        private final List<SortKey> keys;
        private final List<ColumnSchema> schema;
        private final ExecContext ctx;
        private final int batchSize;
        private final long offset;
        private final long limit;
        private final Batch out;
        private ColumnStore store;
        private int[] perm;
        private int pos;
        private int end;
        private long reserved;

        Sort(BatchOperator input, List<SortKey> keys, List<ColumnSchema> schema, ExecContext ctx, int batchSize,
             long offset, long limit) {
            this.input = input;
            this.keys = keys;
            this.schema = schema;
            this.ctx = ctx;
            this.batchSize = batchSize;
            this.offset = offset;
            this.limit = limit;
            this.out = new Batch(schema.size());
            for (int c = 0; c < schema.size(); c++) {
                out.cols[c] = new Vec(schema.get(c).type(), batchSize);
            }
        }

        private void reserve(long bytes) {
            ctx.reserve(bytes);
            reserved += bytes;
        }

        @Override
        public void open() {
            store = new ColumnStore(schema);
            perm = new int[0];
            pos = 0;
            end = 0;
            if (limit == 0) {
                return; // like LIMIT 0 over a sort: the input is never read
            }
            long keep = limit < 0 ? Long.MAX_VALUE : offset + limit < 0 ? Long.MAX_VALUE : offset + limit;
            long compactAt = keep >= Integer.MAX_VALUE / 4 ? Long.MAX_VALUE : Math.max(2 * keep, 2L * batchSize);
            input.open();
            try {
                int[] all = new int[0];
                Batch b;
                while ((b = input.next()) != null) {
                    ctx.checkNow();
                    if (b.count > 0) {
                        if (all.length < b.count) {
                            all = new int[Math.max(b.count, 16)];
                        }
                        for (int k = 0; k < b.count; k++) {
                            all[k] = b.pos(k);
                        }
                        store.append(b, all, b.count);
                        reserve(ColumnStore.estimate(b, all, b.count));
                        if (store.rows() >= compactAt) {
                            int[] order = sort(store, keys, ctx);
                            long kept = reserved * keep / store.rows();
                            store = store.select(order, (int) keep);
                            ctx.release(reserved - kept);
                            reserved = kept;
                        }
                    }
                    if (b.error != null) {
                        throw b.error;
                    }
                }
            } finally {
                input.close();
            }
            perm = sort(store, keys, ctx);
            pos = (int) Math.min(offset, perm.length);
            end = limit < 0 ? perm.length : (int) Math.min(perm.length, keep);
        }

        @Override
        public Batch next() {
            if (pos >= end) {
                return null;
            }
            int n = Math.min(batchSize, end - pos);
            for (int c = 0; c < out.cols.length; c++) {
                Vec src = store.column(c);
                if (src == null) {
                    out.cols[c] = null; // a slot nobody reads
                    continue;
                }
                Vec dst = out.cols[c];
                dst.nullMask(batchSize);
                ColumnStore.gather(src, perm, pos, n, dst, 0);
                dst.hasNulls = src.hasNulls;
            }
            pos += n;
            out.reset(n);
            return out;
        }

        @Override
        public void close() {
            store = null;
            perm = null;
            ctx.release(reserved);
            reserved = 0;
        }
    }
}
