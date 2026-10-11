package polyquery.exec.vector;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import polyquery.exec.ExecContext;
import polyquery.plan.SortKey;
import polyquery.storage.ColumnSchema;
import polyquery.types.Values;

/**
 * Sorting over a column store: ORDER BY (full sort) and ORDER BY … LIMIT (top-N). Rows are
 * ordered by a stable sort of row indices. Every sort key is first normalized to an unsigned
 * 64-bit key per row ({@link KeyColumn}): the value itself for numbers, the rank of the value
 * for dictionary-encoded strings, an order-preserving prefix (with the length) for other
 * strings, the high bits of wide DECIMALs. Rows are radix-sorted on the first key, then runs
 * of equal first keys are refined by a merge sort comparing the normalized keys — and the
 * values only where a key does not determine its value (long strings, wide DECIMALs). Ties
 * keep their input order, exactly like the row engine's stable sort.
 *
 * <p>Large inputs are sorted in parallel: a sample of the first key picks splitters that cut
 * the key range into buckets, rows are distributed to the buckets by a stable parallel
 * counting scatter, and the buckets are sorted independently by the worker threads.
 */
final class SortBatches {
    private static final int INSERTION_RUN = 24;
    /** Inputs from this many rows are sorted in parallel (if the query may use several threads). */
    static final int PARALLEL_SORT_ROWS = 1 << 17;
    /** The parallel sort threshold in effect; system property {@code polyquery.parallelSortRows}. */
    private static final int PARALLEL_SORT_MIN =
            Math.max(2, Integer.getInteger("polyquery.parallelSortRows", PARALLEL_SORT_ROWS));

    private SortBatches() {
    }

    /** Comparison of two rows of a store. */
    interface RowOrder {
        int compare(int a, int b);
    }

    /** How a sort key's normalized 64-bit keys relate to its values. */
    private enum Encoding {
        /** Equal keys ⇔ equal values (numbers, dictionary ranks). */
        EXACT,
        /** Strings: 7 Latin-1 chars and min(length, 8); exact for strings of at most 7 chars. */
        LATIN1,
        /** Strings: 3 UTF-16 units (in code point order) and min(length, 4); exact up to 3 units. */
        UTF16,
        /** Wide DECIMALs: the high 64 bits; equal keys need a full comparison. */
        PREFIX
    }

    /** The normalized keys of one sort key over all rows of a store (unsigned order = value order). */
    private static final class KeyColumn {
        final Vec vec;
        final boolean desc;
        final boolean nullsFirst;
        final long[] keys;
        Encoding encoding;

        KeyColumn(Vec vec, SortKey key, int rows) {
            this.vec = vec;
            this.desc = key.descending();
            this.nullsFirst = key.nullsFirst();
            this.keys = new long[rows];
        }

        /** True if two rows with key {@code k} (non-NULL) are certainly equal in this column. */
        boolean exact(long k) {
            return switch (encoding) {
                case EXACT -> true;
                case LATIN1 -> (k & 0xFF) <= 7;
                case UTF16 -> (k & 0xFFFF) <= 3;
                case PREFIX -> false;
            };
        }

        /** Full comparison of the (non-NULL) values of rows a and b, ascending. */
        int compareValues(int a, int b) {
            return vec.type.isWideDecimal() ? ((BigInteger) vec.objects[a]).compareTo((BigInteger) vec.objects[b])
                    : Values.compareStrings(vec.string(a), vec.string(b));
        }
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
            int c = i < n ? codePointOrder(s.charAt(i)) : 0;
            p = (p << 16) | c;
        }
        return p;
    }

    /** A UTF-16 unit mapped so that unit order is code point order (like {@link Values#compareStrings}). */
    private static int codePointOrder(int c) {
        if (c >= 0xD800) {
            return c >= 0xE000 ? c - 0x800 : c + 0x2000;
        }
        return c;
    }

    /**
     * Lexicographic order of rows by the sort keys (NULL placement independent of direction),
     * comparing the values directly — the reference order the sort implements.
     */
    static RowOrder order(ColumnStore store, List<SortKey> keys) {
        int n = keys.size();
        Vec[] cols = new Vec[n];
        for (int j = 0; j < n; j++) {
            cols[j] = store.column(keys.get(j).column());
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
                    return na == keys.get(j).nullsFirst() ? -1 : 1;
                }
                int c = switch (v.kind) {
                    case LONG -> Long.compare(v.longs[a], v.longs[b]);
                    case DOUBLE -> Values.compareDoubles(v.doubles[a], v.doubles[b]);
                    default -> v.type.isWideDecimal()
                            ? ((BigInteger) v.objects[a]).compareTo((BigInteger) v.objects[b])
                            : Values.compareStrings(v.string(a), v.string(b));
                };
                if (c != 0) {
                    return keys.get(j).descending() ? -c : c;
                }
            }
            return 0;
        };
    }

    /**
     * Row order over the normalized keys, starting at key {@code from} (the keys before it are
     * known to be equal): values are compared only where equal keys do not imply equal values.
     */
    private static RowOrder order(KeyColumn[] cols, int from) {
        return (a, b) -> {
            for (int j = from; j < cols.length; j++) {
                KeyColumn kc = cols[j];
                Vec v = kc.vec;
                if (v.hasNulls) {
                    boolean na = v.nulls[a];
                    boolean nb = v.nulls[b];
                    if (na || nb) {
                        if (na && nb) {
                            continue;
                        }
                        return na == kc.nullsFirst ? -1 : 1;
                    }
                }
                long ka = kc.keys[a];
                long kb = kc.keys[b];
                int c;
                if (ka != kb) {
                    c = Long.compareUnsigned(ka, kb);
                } else if (kc.exact(ka)) {
                    continue;
                } else {
                    c = kc.compareValues(a, b);
                    if (c == 0) {
                        continue;
                    }
                }
                return kc.desc ? -c : c;
            }
            return 0;
        };
    }

    /**
     * Row indices {@code 0..rows-1} of {@code store} in sort order (stable), sequentially.
     */
    static int[] sort(ColumnStore store, List<SortKey> keys, ExecContext ctx) {
        return sort(store, keys, ctx, 1);
    }

    /**
     * Row indices {@code 0..rows-1} of {@code store} in sort order (stable): the rows are
     * radix-sorted on the normalized first key (in parallel buckets for large inputs when
     * {@code threads > 1}), then runs of equal first keys are refined by a merge sort with the
     * full row order (if needed).
     */
    static int[] sort(ColumnStore store, List<SortKey> keys, ExecContext ctx, int threads) {
        int n = store.rows();
        if (n == 0) {
            return new int[0];
        }
        boolean parallel = threads > 1 && n >= PARALLEL_SORT_MIN;
        int tasks = parallel ? threads : 1;
        KeyColumn[] cols = new KeyColumn[keys.size()];
        for (int j = 0; j < cols.length; j++) {
            cols[j] = new KeyColumn(store.column(keys.get(j).column()), keys.get(j), n);
            normalize(cols[j], n, tasks, ctx);
        }
        KeyColumn first = cols[0];
        Vec v = first.vec;
        // the non-NULL rows with their first keys (complemented when descending), in input order
        int nullCount = 0;
        if (v.hasNulls) {
            for (int i = 0; i < n; i++) {
                if (v.nulls[i]) {
                    nullCount++;
                }
            }
        }
        int m = n - nullCount;
        long flip = first.desc ? -1L : 0L;
        long[] sortKeys = new long[m];
        int[] ids = new int[m];
        int[] out = new int[n];
        int nullAt = first.nullsFirst ? 0 : m;
        if (nullCount == 0) {
            for (int i = 0; i < n; i++) {
                sortKeys[i] = first.keys[i] ^ flip;
                ids[i] = i;
            }
        } else {
            int k = 0;
            for (int i = 0; i < n; i++) {
                if (v.nulls[i]) {
                    out[nullAt++] = i;
                } else {
                    sortKeys[k] = first.keys[i] ^ flip;
                    ids[k++] = i;
                }
            }
        }
        Refiner refiner = new Refiner(cols);
        if (parallel && m >= PARALLEL_SORT_MIN) {
            sortParallel(sortKeys, ids, m, refiner, threads, ctx);
        } else {
            long[] tk = new long[m];
            int[] ti = new int[m];
            if (radix(sortKeys, ids, tk, ti, 0, m, ctx)) {
                System.arraycopy(tk, 0, sortKeys, 0, m);
                System.arraycopy(ti, 0, ids, 0, m);
            }
            refiner.refine(sortKeys, ids, 0, m, ti, ctx);
        }
        System.arraycopy(ids, 0, out, first.nullsFirst ? nullCount : 0, m);
        if (nullCount > 1 && cols.length > 1) {
            // rows with a NULL first key are ordered by the remaining keys
            int from = first.nullsFirst ? 0 : m;
            mergeSort(out, new int[n], from, from + nullCount, order(cols, 1), ctx);
        }
        return out;
    }

    /** Refines runs of equal first keys with the remaining row order. */
    private static final class Refiner {
        private final KeyColumn first;
        /** Order for runs whose first key is exact (starts at the second key), else null: no refinement. */
        private final RowOrder afterFirst;
        private final RowOrder full;

        Refiner(KeyColumn[] cols) {
            this.first = cols[0];
            this.afterFirst = cols.length > 1 ? order(cols, 1) : null;
            this.full = order(cols, 0);
        }

        /** Sorts each run of equal keys in the sorted range [from, to) of (keys, ids); tmp is scratch. */
        void refine(long[] keys, int[] ids, int from, int to, int[] tmp, ExecContext ctx) {
            if (afterFirst == null && first.encoding == Encoding.EXACT) {
                return; // the radix key is the whole sort key
            }
            long flip = first.desc ? -1L : 0L;
            int i = from;
            while (i < to) {
                long k = keys[i];
                int j = i + 1;
                while (j < to && keys[j] == k) {
                    j++;
                }
                if (j - i > 1) {
                    RowOrder order = first.exact(k ^ flip) ? afterFirst : full;
                    if (order != null) {
                        mergeSort(ids, tmp, i, j, order, ctx);
                    }
                }
                i = j;
            }
        }
    }

    /** Indices {@code 0..n-1} ordered (stably) by the unsigned keys {@code keys[0..n)} (not modified). */
    static int[] orderByKey(long[] keys, int n, ExecContext ctx) {
        long[] k = Arrays.copyOf(keys, n);
        int[] ids = new int[n];
        for (int i = 0; i < n; i++) {
            ids[i] = i;
        }
        long[] tk = new long[n];
        int[] ti = new int[n];
        return radix(k, ids, tk, ti, 0, n, ctx) ? ti : ids;
    }

    /**
     * Fills {@code col.keys} (rows whose value is NULL get an arbitrary key) and picks the
     * encoding, in {@code tasks} parallel chunks.
     */
    private static void normalize(KeyColumn col, int n, int tasks, ExecContext ctx) {
        Vec v = col.vec;
        long[] keys = col.keys;
        switch (v.kind) {
            case LONG -> {
                col.encoding = Encoding.EXACT;
                long[] s = v.longs;
                chunked(n, tasks, ctx, (from, to) -> {
                    for (int i = from; i < to; i++) {
                        keys[i] = s[i] ^ Long.MIN_VALUE;
                    }
                });
            }
            case DOUBLE -> {
                col.encoding = Encoding.EXACT;
                double[] s = v.doubles;
                chunked(n, tasks, ctx, (from, to) -> {
                    for (int i = from; i < to; i++) {
                        double d = s[i];
                        long bits = Double.doubleToLongBits(d == 0.0 ? 0.0 : d);
                        keys[i] = bits < 0 ? ~bits : bits ^ Long.MIN_VALUE;
                    }
                });
            }
            case DICT -> {
                if (v.dict.length <= n) {
                    col.encoding = Encoding.EXACT;
                    long[] rank = dictionaryRanks(v.dict);
                    int[] codes = v.codes;
                    boolean[] nulls = v.hasNulls ? v.nulls : null;
                    chunked(n, tasks, ctx, (from, to) -> {
                        for (int i = from; i < to; i++) {
                            keys[i] = nulls != null && nulls[i] ? 0 : rank[codes[i]];
                        }
                    });
                } else {
                    stringKeys(col, n, tasks, ctx);
                }
            }
            case OBJECT -> {
                if (v.type.isWideDecimal()) {
                    col.encoding = Encoding.PREFIX;
                    Object[] s = v.objects;
                    chunked(n, tasks, ctx, (from, to) -> {
                        for (int i = from; i < to; i++) {
                            keys[i] = s[i] == null ? 0
                                    : ((BigInteger) s[i]).shiftRight(64).longValue() ^ Long.MIN_VALUE;
                        }
                    });
                } else {
                    stringKeys(col, n, tasks, ctx);
                }
            }
        }
    }

    /** Ranks of the dictionary's strings in code point order (equal strings, equal ranks). */
    private static long[] dictionaryRanks(String[] dict) {
        Integer[] byValue = new Integer[dict.length];
        for (int i = 0; i < dict.length; i++) {
            byValue[i] = i;
        }
        Arrays.sort(byValue, (a, b) -> Values.compareStrings(dict[a], dict[b]));
        long[] rank = new long[dict.length];
        long r = 0;
        for (int i = 0; i < byValue.length; i++) {
            if (i > 0 && Values.compareStrings(dict[byValue[i - 1]], dict[byValue[i]]) != 0) {
                r++;
            }
            rank[byValue[i]] = r;
        }
        return rank;
    }

    /** String keys: Latin-1 encoding if the first 7 chars of every string are Latin-1, else UTF-16. */
    private static void stringKeys(KeyColumn col, int n, int tasks, ExecContext ctx) {
        Vec v = col.vec;
        long[] keys = col.keys;
        boolean[] nulls = v.hasNulls ? v.nulls : null;
        AtomicInteger wide = new AtomicInteger();
        chunked(n, tasks, ctx, (from, to) -> {
            int or = 0;
            for (int i = from; i < to; i++) {
                if (nulls != null && nulls[i]) {
                    continue;
                }
                String s = v.string(i);
                int len = s.length();
                int lim = Math.min(7, len);
                long k = 0;
                for (int c = 0; c < 7; c++) {
                    int ch = c < lim ? s.charAt(c) : 0;
                    or |= ch;
                    k = (k << 8) | (ch & 0xFF);
                }
                keys[i] = (k << 8) | Math.min(len, 8);
            }
            if (or > 0xFF) {
                wide.incrementAndGet();
            }
        });
        if (wide.get() == 0) {
            col.encoding = Encoding.LATIN1;
            return;
        }
        col.encoding = Encoding.UTF16;
        chunked(n, tasks, ctx, (from, to) -> {
            for (int i = from; i < to; i++) {
                if (nulls != null && nulls[i]) {
                    continue;
                }
                String s = v.string(i);
                int len = s.length();
                int lim = Math.min(3, len);
                long k = 0;
                for (int c = 0; c < 3; c++) {
                    k = (k << 16) | (c < lim ? codePointOrder(s.charAt(c)) : 0);
                }
                keys[i] = (k << 16) | Math.min(len, 4);
            }
        });
    }

    /** A task over the row range [from, to). */
    private interface RangeTask {
        void run(int from, int to);
    }

    /** Runs {@code task} over [0, n) in {@code tasks} contiguous chunks on the worker pool. */
    private static void chunked(int n, int tasks, ExecContext ctx, RangeTask task) {
        int t = Math.max(1, Math.min(tasks, n / 4096));
        if (t == 1) {
            task.run(0, n);
            return;
        }
        List<Runnable> runs = new ArrayList<>(t);
        for (int c = 0; c < t; c++) {
            int from = (int) ((long) n * c / t);
            int to = (int) ((long) n * (c + 1) / t);
            runs.add(() -> task.run(from, to));
        }
        Parallel.runAll(runs, ctx);
    }

    /**
     * Parallel stable sort of {@code (keys, ids)[0, m)} by key: splitters from a sample cut the
     * key range into buckets; each chunk of the input counts its rows per bucket, a prefix sum
     * gives every (bucket, chunk) its output position, so a parallel scatter keeps input order
     * within buckets; then the buckets are radix-sorted and refined independently.
     */
    private static void sortParallel(long[] keys, int[] ids, int m, Refiner refiner, int threads, ExecContext ctx) {
        long[] splitters = splitters(keys, m, threads * 16);
        int buckets = splitters.length + 1;
        int chunks = threads;
        int[][] counts = new int[chunks][buckets];
        int[] bucketOf = new int[m];
        List<Runnable> count = new ArrayList<>(chunks);
        for (int c = 0; c < chunks; c++) {
            int chunk = c;
            count.add(() -> {
                int[] cnt = counts[chunk];
                int from = (int) ((long) m * chunk / chunks);
                int to = (int) ((long) m * (chunk + 1) / chunks);
                for (int i = from; i < to; i++) {
                    int b = bucket(splitters, keys[i]);
                    bucketOf[i] = b;
                    cnt[b]++;
                }
            });
        }
        Parallel.runAll(count, ctx);
        int[] bucketStart = new int[buckets + 1];
        int pos = 0;
        for (int b = 0; b < buckets; b++) {
            bucketStart[b] = pos;
            for (int c = 0; c < chunks; c++) {
                int k = counts[c][b];
                counts[c][b] = pos;
                pos += k;
            }
        }
        bucketStart[buckets] = m;
        long[] tk = new long[m];
        int[] ti = new int[m];
        List<Runnable> scatter = new ArrayList<>(chunks);
        for (int c = 0; c < chunks; c++) {
            int chunk = c;
            scatter.add(() -> {
                int[] at = counts[chunk];
                int from = (int) ((long) m * chunk / chunks);
                int to = (int) ((long) m * (chunk + 1) / chunks);
                for (int i = from; i < to; i++) {
                    int p = at[bucketOf[i]]++;
                    tk[p] = keys[i];
                    ti[p] = ids[i];
                }
            });
        }
        Parallel.runAll(scatter, ctx);
        // the buckets, largest first, are sorted by the workers; results end in (keys, ids)
        Integer[] order = new Integer[buckets];
        for (int b = 0; b < buckets; b++) {
            order[b] = b;
        }
        Arrays.sort(order, (a, b) -> Integer.compare(bucketStart[b + 1] - bucketStart[b],
                bucketStart[a + 1] - bucketStart[a]));
        AtomicInteger next = new AtomicInteger();
        List<Runnable> work = new ArrayList<>(threads);
        for (int t = 0; t < threads; t++) {
            work.add(() -> {
                int k;
                while ((k = next.getAndIncrement()) < buckets) {
                    int b = order[k];
                    int from = bucketStart[b];
                    int to = bucketStart[b + 1];
                    if (to - from == 0) {
                        continue;
                    }
                    if (!radix(tk, ti, keys, ids, from, to, ctx)) {
                        System.arraycopy(tk, from, keys, from, to - from);
                        System.arraycopy(ti, from, ids, from, to - from);
                    }
                    refiner.refine(keys, ids, from, to, ti, ctx);
                }
            });
        }
        Parallel.runAll(work, ctx);
    }

    /** Up to {@code buckets - 1} distinct splitters (unsigned ascending) from a regular sample of the keys. */
    private static long[] splitters(long[] keys, int m, int buckets) {
        int samples = Math.min(m, buckets * 32);
        long[] sample = new long[samples];
        for (int s = 0; s < samples; s++) {
            sample[s] = keys[(int) ((long) m * s / samples)] ^ Long.MIN_VALUE; // signed order = unsigned order
        }
        Arrays.sort(sample);
        long[] out = new long[buckets - 1];
        int k = 0;
        for (int b = 1; b < buckets; b++) {
            long s = sample[(int) ((long) samples * b / buckets)];
            if (k == 0 || out[k - 1] != s) {
                out[k++] = s;
            }
        }
        long[] result = Arrays.copyOf(out, k);
        for (int i = 0; i < k; i++) {
            result[i] ^= Long.MIN_VALUE;
        }
        return result;
    }

    /** Number of splitters {@code <= key} (unsigned): equal keys share a bucket, buckets are ordered. */
    private static int bucket(long[] splitters, long key) {
        int lo = 0;
        int hi = splitters.length;
        while (lo < hi) {
            int mid = (lo + hi) >>> 1;
            if (Long.compareUnsigned(splitters[mid], key) <= 0) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    /**
     * Stable LSD radix sort (8 bits per pass, bytes constant over the range skipped) of
     * {@code (keys, ids)[from, to)} by unsigned key, using {@code (tk, ti)} as scratch. Returns
     * true if the sorted range ended up in the scratch arrays.
     */
    private static boolean radix(long[] keys, int[] ids, long[] tk, int[] ti, int from, int to, ExecContext ctx) {
        int n = to - from;
        if (n <= INSERTION_RUN) {
            for (int i = from + 1; i < to; i++) {
                long k = keys[i];
                int id = ids[i];
                int j = i - 1;
                while (j >= from && Long.compareUnsigned(keys[j], k) > 0) {
                    keys[j + 1] = keys[j];
                    ids[j + 1] = ids[j];
                    j--;
                }
                keys[j + 1] = k;
                ids[j + 1] = id;
            }
            return false;
        }
        long and = -1L;
        long or = 0;
        for (int i = from; i < to; i++) {
            and &= keys[i];
            or |= keys[i];
        }
        long varying = and ^ or;
        boolean swapped = false;
        int[] count = new int[257];
        for (int shift = 0; shift < 64; shift += 8) {
            if (((varying >>> shift) & 0xFF) == 0) {
                continue; // every key has the same byte here: nothing to reorder
            }
            Arrays.fill(count, 0);
            for (int i = from; i < to; i++) {
                count[(int) ((keys[i] >>> shift) & 0xFF) + 1]++;
            }
            count[0] = from;
            for (int b = 0; b < 256; b++) {
                count[b + 1] += count[b];
            }
            for (int i = from; i < to; i++) {
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
            swapped = !swapped;
            if (n > 65_536) {
                ctx.checkNow();
            }
        }
        return swapped;
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
     * Top-N pre-filter: once the best {@code keep} rows so far are known, a row whose first sort
     * key ranks strictly after the first key of the {@code keep}-th row cannot be among the
     * result, so it is dropped before it is materialized (rows with an equal first key are kept:
     * later keys and input order decide). Only for INT64-like and FLOAT64 first keys.
     */
    static final class Cutoff {
        private final SortKey key;
        private final long flip;
        private boolean active;
        private long threshold;

        Cutoff(SortKey key) {
            this.key = key;
            this.flip = key.descending() ? -1L : 0L;
        }

        /** Sets the threshold from row {@code row} of {@code store}, the current {@code keep}-th best row. */
        void update(ColumnStore store, int row) {
            Vec v = store.column(key.column());
            active = v != null && (v.kind == Vec.Kind.LONG || v.kind == Vec.Kind.DOUBLE) && !v.isNull(row);
            if (active) {
                threshold = normalized(v, row);
            }
        }

        private long normalized(Vec v, int i) {
            long k;
            if (v.kind == Vec.Kind.LONG) {
                k = v.longs[i] ^ Long.MIN_VALUE;
            } else {
                double d = v.doubles[i];
                long bits = Double.doubleToLongBits(d == 0.0 ? 0.0 : d);
                k = bits < 0 ? ~bits : bits ^ Long.MIN_VALUE;
            }
            return k ^ flip;
        }

        /** Writes the positions of the active rows of {@code b} that may still be in the result to {@code out}; returns their number. */
        int filter(Batch b, int[] out) {
            Vec v = b.cols[key.column()];
            int m = 0;
            if (!active || v == null || (v.kind != Vec.Kind.LONG && v.kind != Vec.Kind.DOUBLE)) {
                for (int k = 0; k < b.count; k++) {
                    out[k] = b.pos(k);
                }
                return b.count;
            }
            // the threshold row is not NULL: NULLs rank before it (NULLS FIRST) or after it
            boolean keepNulls = key.nullsFirst();
            for (int k = 0; k < b.count; k++) {
                int i = b.pos(k);
                boolean pass = v.isNull(i) ? keepNulls : Long.compareUnsigned(normalized(v, i), threshold) <= 0;
                if (pass) {
                    out[m++] = i;
                }
            }
            return m;
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
        private final int threads;
        private final long offset;
        private final long limit;
        private final Batch out;
        private ColumnStore store;
        private int[] perm;
        private int pos;
        private int end;
        private long reserved;

        /** @param threads worker threads the sort itself may use (large inputs are sorted in parallel) */
        Sort(BatchOperator input, List<SortKey> keys, List<ColumnSchema> schema, ExecContext ctx, int batchSize,
             int threads, long offset, long limit) {
            this.input = input;
            this.keys = keys;
            this.schema = schema;
            this.ctx = ctx;
            this.batchSize = batchSize;
            this.threads = threads;
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
            Cutoff cutoff = limit < 0 ? null : new Cutoff(keys.getFirst());
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
                        int m;
                        if (cutoff != null) {
                            m = cutoff.filter(b, all);
                        } else {
                            for (int k = 0; k < b.count; k++) {
                                all[k] = b.pos(k);
                            }
                            m = b.count;
                        }
                        store.append(b, all, m);
                        reserve(ColumnStore.estimate(b, all, m));
                        if (store.rows() >= compactAt) {
                            int[] order = sort(store, keys, ctx, threads);
                            long kept = reserved * keep / store.rows();
                            store = store.select(order, (int) keep);
                            ctx.release(reserved - kept);
                            reserved = kept;
                            if (cutoff != null) {
                                cutoff.update(store, (int) keep - 1);
                            }
                        }
                    }
                    if (b.error != null) {
                        throw b.error;
                    }
                }
            } finally {
                input.close();
            }
            perm = sort(store, keys, ctx, threads);
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
