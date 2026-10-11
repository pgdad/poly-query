package polyquery.exec.vector;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Random;
import polyquery.exec.ExecContext;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.plan.SortKey;
import polyquery.storage.ColumnSchema;
import polyquery.types.DataType;
import polyquery.types.Values;

/** White-box tests of the vectorized engine's building blocks. */
public final class VectorTest {
    private VectorTest() {
    }

    private static void check(boolean cond, String msg) {
        if (!cond) {
            throw new AssertionError(msg);
        }
    }

    private static ExecContext ctx() {
        return new ExecContext(0, Long.MAX_VALUE, -1, Long.MAX_VALUE);
    }

    private static Vec longs(DataType t, Long... values) {
        Vec v = new Vec(t, values.length);
        v.nullMask(values.length);
        for (int i = 0; i < values.length; i++) {
            v.set(i, values[i]);
        }
        return v;
    }

    private static Vec strings(String... values) {
        Vec v = new Vec(DataType.STRING, values.length);
        v.nullMask(values.length);
        for (int i = 0; i < values.length; i++) {
            v.set(i, values[i]);
        }
        return v;
    }

    /** Branch-free signed comparison agrees with Long.compare, including extremes. */
    public static void testBranchFreeLess() {
        long[] edge = {0, 1, -1, Long.MAX_VALUE, Long.MIN_VALUE, 1L << 62, -(1L << 62), 7, -7};
        Random r = new Random(1);
        List<Long> vals = new ArrayList<>();
        for (long e : edge) {
            vals.add(e);
        }
        for (int i = 0; i < 200; i++) {
            vals.add(r.nextLong());
        }
        for (long x : vals) {
            for (long y : vals) {
                check(Kernels.less(x, y) == (x < y ? 1 : 0), "less(" + x + ", " + y + ")");
            }
        }
    }

    /** Group ids follow first appearance; NULLs form one group; dictionary and plain strings agree. */
    public static void testGroupKeys() {
        GroupKeys keys = new GroupKeys(new DataType[] {DataType.INT64, DataType.STRING}, null);
        Vec a = longs(DataType.INT64, 5L, 5L, null, 7L, null, 5L);
        Vec b = strings("x", "y", null, "x", null, "x");
        int[] gids = new int[6];
        keys.groupIds(new Vec[] {a, b}, null, 6, 6, gids);
        check(Arrays.equals(gids, new int[] {0, 1, 2, 3, 2, 0}), "gids " + Arrays.toString(gids));
        Vec dict = new Vec(DataType.STRING, 3);
        dict.toDict(new String[] {"y", "x"}, 3);
        dict.codes[0] = 1;
        dict.codes[1] = 0;
        dict.codes[2] = 0;
        dict.hasNulls = false;
        Vec a2 = longs(DataType.INT64, 7L, 5L, 9L);
        keys.groupIds(new Vec[] {a2, dict}, null, 3, 3, gids);
        check(gids[0] == 3 && gids[1] == 1 && gids[2] == 4, "dictionary gids " + Arrays.toString(gids));
        // a second table hashes equal keys equally (partitioned parallel merge relies on it)
        GroupKeys other = new GroupKeys(new DataType[] {DataType.INT64, DataType.STRING}, null);
        other.groupIds(new Vec[] {longs(DataType.INT64, 7L), strings("x")}, null, 1, 1, gids);
        check(other.hash(0) == keys.hash(3), "value-based hashes");
        check(keys.addFrom(other, 0) == 3, "merge into existing group");
    }

    /** Exact sums: long overflow widens to BigInteger, both per group and in the SIMD single-group path. */
    public static void testExactSums() {
        AggregateCall sum = new AggregateCall(AggregateCall.AggregateFunction.SUM,
                new BoundExpr.ColumnRef(0, DataType.INT64, "x"), false, DataType.INT64);
        Vec big = longs(DataType.INT64, Long.MAX_VALUE, Long.MAX_VALUE, -Long.MAX_VALUE, -10L);
        AggState single = AggState.create(sum, null);
        single.grow(1);
        single.updateSingle(big, null, 4, new int[4]);
        check(Long.valueOf(Long.MAX_VALUE - 10).equals(single.result(0)), "single-group sum");
        single.updateSingle(longs(DataType.INT64, Long.MIN_VALUE, Long.MAX_VALUE), null, 2, new int[2]);
        check(Long.valueOf(Long.MAX_VALUE - 11).equals(single.result(0)), "single-group sum after widening");
        AggState grouped = AggState.create(sum, null);
        grouped.grow(1);
        grouped.update(longs(DataType.INT64, Long.MAX_VALUE, 10L, -20L), null, 3, new int[3]);
        check(Long.valueOf(Long.MAX_VALUE - 10).equals(grouped.result(0)), "grouped overflowing sum");
        AggState overflow = AggState.create(sum, null);
        overflow.grow(1);
        overflow.updateSingle(longs(DataType.INT64, Long.MAX_VALUE, 1L), null, 2, new int[2]);
        try {
            overflow.result(0);
            throw new AssertionError("expected NUMERIC_OVERFLOW");
        } catch (polyquery.common.PolyQueryException e) {
            check(e.code() == polyquery.common.ErrorCode.NUMERIC_OVERFLOW, "overflow code");
        }
        // merging partial states is exact as well
        AggState p1 = AggState.create(sum, null);
        AggState p2 = AggState.create(sum, null);
        p1.grow(1);
        p2.grow(1);
        p1.updateSingle(longs(DataType.INT64, Long.MAX_VALUE), null, 1, new int[1]);
        p2.updateSingle(longs(DataType.INT64, Long.MAX_VALUE, -Long.MAX_VALUE), null, 2, new int[2]);
        p1.merge(p2, 0, 0);
        check(Long.valueOf(Long.MAX_VALUE).equals(p1.result(0)), "merged sum");
    }

    /** The radix/merge sort is stable and orders like the row engine's comparator. */
    public static void testSortIsStable() {
        List<ColumnSchema> schema = List.of(new ColumnSchema("k", DataType.FLOAT64),
                new ColumnSchema("s", DataType.STRING), new ColumnSchema("seq", DataType.INT64));
        ColumnStore store = new ColumnStore(schema);
        Random r = new Random(7);
        int n = 500;
        Batch b = new Batch(3);
        b.cols[0] = new Vec(DataType.FLOAT64, n);
        b.cols[1] = new Vec(DataType.STRING, n);
        b.cols[2] = new Vec(DataType.INT64, n);
        for (Vec v : b.cols) {
            v.nullMask(n);
        }
        String[] words = {"b", "a", "ab", "😀", "｡", "", "ba"};
        for (int i = 0; i < n; i++) {
            b.cols[0].set(i, r.nextInt(10) == 0 ? null : (double) (r.nextInt(9) - 4) * (r.nextBoolean() ? 1 : -1));
            b.cols[1].set(i, r.nextInt(8) == 0 ? null : words[r.nextInt(words.length)]);
            b.cols[2].set(i, (long) i);
        }
        b.reset(n);
        int[] all = new int[n];
        for (int i = 0; i < n; i++) {
            all[i] = i;
        }
        store.append(b, all, n);
        for (List<SortKey> keys : List.of(List.of(new SortKey(0, true, false)),
                List.of(new SortKey(1, false, true)), List.of(new SortKey(1, true, false), new SortKey(0, false, true)))) {
            int[] perm = SortBatches.sort(store, keys, ctx());
            SortBatches.RowOrder order = SortBatches.order(store, keys);
            for (int i = 1; i < n; i++) {
                int c = order.compare(perm[i - 1], perm[i]);
                check(c < 0 || c == 0 && perm[i - 1] < perm[i], "stable order at " + i + " for " + keys);
            }
        }
        check(Values.compareStrings("😀", "｡") > 0, "code point order");
        check(Long.compareUnsigned(SortBatches.prefix("😀"), SortBatches.prefix("｡")) > 0,
                "prefix keeps code point order");
    }

    /**
     * The parallel bucket sort and the normalized string keys (Latin-1 and UTF-16, short and
     * long strings, dictionary ranks) order exactly like the reference comparator, stably.
     */
    public static void testParallelSortMatchesReference() {
        List<ColumnSchema> schema = List.of(new ColumnSchema("s", DataType.STRING),
                new ColumnSchema("k", DataType.INT64), new ColumnSchema("d", DataType.STRING),
                new ColumnSchema("f", DataType.FLOAT64));
        Random r = new Random(11);
        int n = SortBatches.PARALLEL_SORT_ROWS + 4321;
        String[] dict = {"pear", "apple", "fig", "apple", "", "kiwi\u0000", "kiwi"};
        for (boolean latin1 : new boolean[] {true, false}) {
            Batch b = new Batch(4);
            b.cols[0] = new Vec(DataType.STRING, n);
            b.cols[1] = new Vec(DataType.INT64, n);
            b.cols[2] = new Vec(DataType.STRING, n);
            b.cols[3] = new Vec(DataType.FLOAT64, n);
            for (Vec v : b.cols) {
                v.nullMask(n);
            }
            b.cols[2].toDict(dict, n);
            for (int i = 0; i < n; i++) {
                StringBuilder sb = new StringBuilder();
                int len = r.nextInt(11);
                for (int c = 0; c < len; c++) {
                    sb.append(latin1 || r.nextInt(5) > 0 ? (char) ('a' + r.nextInt(3)) : "😀｡\u0000é".charAt(r.nextInt(5)));
                }
                b.cols[0].set(i, r.nextInt(50) == 0 ? null : sb.toString());
                b.cols[1].set(i, r.nextInt(30) == 0 ? null : (long) r.nextInt(100) - 50);
                b.cols[2].codes[i] = r.nextInt(dict.length);
                b.cols[2].nulls[i] = r.nextInt(20) == 0;
                b.cols[3].set(i, (double) r.nextInt(7) - 3.0);
            }
            b.reset(n);
            int[] all = new int[n];
            for (int i = 0; i < n; i++) {
                all[i] = i;
            }
            ColumnStore store = new ColumnStore(schema);
            store.append(b, all, n);
            for (List<SortKey> keys : List.of(List.of(new SortKey(0, false, true)),
                    List.of(new SortKey(0, true, false), new SortKey(1, false, true)),
                    List.of(new SortKey(1, true, true), new SortKey(0, false, false)),
                    List.of(new SortKey(2, false, false), new SortKey(3, true, false)),
                    List.of(new SortKey(3, false, false), new SortKey(2, true, true), new SortKey(1, false, true)))) {
                SortBatches.RowOrder order = SortBatches.order(store, keys);
                for (int threads : new int[] {1, 8}) {
                    int[] perm = SortBatches.sort(store, keys, ctx(), threads);
                    check(perm.length == n, "permutation size");
                    for (int i = 1; i < n; i++) {
                        int c = order.compare(perm[i - 1], perm[i]);
                        check(c < 0 || c == 0 && perm[i - 1] < perm[i],
                                "stable order at " + i + " for " + keys + " threads " + threads + " latin1 " + latin1);
                    }
                }
            }
        }
    }

    /** The single-key join index chains rows with equal keys in insertion order. */
    public static void testLongIndex() {
        JoinBatches.LongIndex index = new JoinBatches.LongIndex();
        int[] next = new int[5000];
        for (int r = 0; r < 5000; r++) {
            index.add(r % 1000 * 7919L, r, next);
        }
        for (int k = 0; k < 1000; k++) {
            int row = index.head(k * 7919L);
            int count = 0;
            int last = -1;
            while (row >= 0) {
                check(row % 1000 == k && row > last, "chain order");
                last = row;
                row = next[row];
                count++;
            }
            check(count == 5, "chain length");
        }
        check(index.head(-1) == -1, "absent key");
    }

    /** k-way merge of sorted runs. */
    public static void testKWayMerge() {
        long[][] keys = {{1, 4, 9}, {2, 3, 10, 11}, {}, {0}};
        int[] sizes = {3, 4, 0, 1};
        long[] out = new long[8];
        Parallel.kWayMerge(keys, sizes, (s, i, p) -> out[p] = keys[s][i]);
        check(Arrays.equals(out, new long[] {0, 1, 2, 3, 4, 9, 10, 11}), Arrays.toString(out));
    }
}
