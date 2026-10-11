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

    /** LongSet agrees with a HashSet, including the slot sentinel value and growth. */
    public static void testLongSet() {
        LongSet set = new LongSet(4);
        java.util.Set<Long> ref = new java.util.HashSet<>();
        Random r = new Random(5);
        for (int i = 0; i < 20_000; i++) {
            long v = switch (i % 4) {
                case 0 -> Long.MIN_VALUE;
                case 1 -> r.nextInt(5000);
                default -> r.nextLong();
            };
            check(set.add(v) == ref.add(v), "add " + v);
        }
        check(set.size() == ref.size(), "size");
        for (int i = 0; i < 5000; i++) {
            long v = r.nextInt(10_000);
            check(set.contains(v) == ref.contains(v), "contains " + v);
        }
        check(set.contains(Long.MIN_VALUE), "sentinel value");
    }

    /** PairSet distinguishes the group and the value of a pair. */
    public static void testPairSet() {
        AggState.PairSet set = new AggState.PairSet();
        java.util.Set<List<Long>> ref = new java.util.HashSet<>();
        Random r = new Random(9);
        for (int i = 0; i < 50_000; i++) {
            int g = r.nextInt(50);
            long v = r.nextInt(300) - 150;
            check(set.add(g, v) == ref.add(List.of((long) g, v)), "pair " + g + "," + v);
        }
    }

    /** A DISTINCT aggregate merged from partial states equals the one computed in one piece. */
    public static void testDistinctStateMerge() {
        BoundExpr arg = new BoundExpr.ColumnRef(0, DataType.STRING, "s");
        AggregateCall count = new AggregateCall(AggregateCall.AggregateFunction.COUNT, arg, true, DataType.INT64);
        AggregateCall min = new AggregateCall(AggregateCall.AggregateFunction.MIN, arg, true, DataType.STRING);
        for (AggregateCall call : List.of(count, min)) {
            AggState whole = AggState.create(call, null);
            AggState a = AggState.create(call, null);
            AggState b = AggState.create(call, null);
            check(whole instanceof AggState.Distinct && whole.mergeable(), "primitive distinct state");
            Vec v1 = strings("x", "y", null, "x", "z");
            Vec v2 = strings("z", "w", "x", "w", "q");
            int[] g1 = {0, 1, 0, 0, 1};
            int[] g2 = {1, 0, 0, 1, 0};
            for (AggState s : List.of(whole, a, b)) {
                s.grow(2);
            }
            whole.update(v1, null, 5, g1);
            whole.update(v2, null, 5, g2);
            a.update(v1, null, 5, g1);
            b.update(v2, null, 5, g2);
            a.prepareMerge();
            b.prepareMerge();
            AggState merged = AggState.create(call, null);
            merged.grow(2);
            for (int g = 0; g < 2; g++) {
                merged.merge(a, g, g);
                merged.merge(b, g, g);
            }
            for (int g = 0; g < 2; g++) {
                check(java.util.Objects.equals(whole.result(g), merged.result(g)),
                        call.function() + " group " + g + ": " + whole.result(g) + " vs " + merged.result(g));
            }
            if (call == count) {
                check(Long.valueOf(3).equals(whole.result(0)) && Long.valueOf(3).equals(whole.result(1)),
                        "distinct counts " + whole.result(0) + "," + whole.result(1));
            }
        }
    }
}
