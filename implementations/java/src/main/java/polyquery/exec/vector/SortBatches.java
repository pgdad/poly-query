package polyquery.exec.vector;

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

    /**
     * An unsigned 64-bit prefix of a string consistent with code point order: the first four
     * UTF-16 units mapped like {@link Values#compareStrings} (surrogates above the BMP), zero
     * padded. Different prefixes order like the strings; equal prefixes need a full comparison.
     */
    static long prefix(String s) {
        long p = 0;
        int n = Math.min(4, s.length());
        for (int i = 0; i < 4; i++) {
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

    /** Lexicographic order of rows by the sort keys (NULL placement independent of direction). */
    static RowOrder order(ColumnStore store, List<SortKey> keys) {
        int n = keys.size();
        Vec[] cols = new Vec[n];
        long[][] prefixes = new long[n][];
        boolean[] desc = new boolean[n];
        boolean[] nullsFirst = new boolean[n];
        for (int j = 0; j < n; j++) {
            cols[j] = store.column(keys.get(j).column());
            desc[j] = keys.get(j).descending();
            nullsFirst[j] = keys.get(j).nullsFirst();
            if (cols[j].kind == Vec.Kind.OBJECT) {
                long[] p = new long[store.rows()];
                for (int i = 0; i < p.length; i++) {
                    if (!cols[j].isNull(i)) {
                        p[i] = prefix((String) cols[j].objects[i]);
                    }
                }
                prefixes[j] = p;
            }
        }
        return (a, b) -> {
            for (int j = 0; j < n; j++) {
                Vec v = cols[j];
                boolean na = v.isNull(a);
                boolean nb = v.isNull(b);
                if (na || nb) {
                    if (na && nb) {
                        continue;
                    }
                    return na == nullsFirst[j] ? -1 : 1;
                }
                int c = switch (v.kind) {
                    case LONG -> Long.compare(v.longs[a], v.longs[b]);
                    case DOUBLE -> Values.compareDoubles(v.doubles[a], v.doubles[b]);
                    default -> {
                        int pc = Long.compareUnsigned(prefixes[j][a], prefixes[j][b]);
                        yield pc != 0 ? pc : Values.compareStrings((String) v.objects[a], (String) v.objects[b]);
                    }
                };
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
        SortKey first = keys.getFirst();
        Vec v = store.column(first.column());
        long[] sortedKeys = new long[n];
        int[] idx = radix(v, n, first, sortedKeys, ctx);
        if (keys.size() == 1 && v.kind != Vec.Kind.OBJECT) {
            return idx; // the radix key is the whole sort key
        }
        RowOrder order = order(store, keys);
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

    /** An unsigned 64-bit key whose order is the value order (doubles: -0.0 equals 0.0). */
    private static long sortKey(Vec v, int i) {
        return switch (v.kind) {
            case LONG -> v.longs[i] ^ Long.MIN_VALUE;
            case DOUBLE -> {
                double d = v.doubles[i];
                long bits = Double.doubleToLongBits(d == 0.0 ? 0.0 : d);
                yield bits < 0 ? ~bits : bits ^ Long.MIN_VALUE;
            }
            default -> prefix((String) v.objects[i]);
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
                Vec dst = out.cols[c];
                dst.nullMask(batchSize);
                ColumnStore.gather(store.column(c), perm, pos, n, dst, 0);
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
