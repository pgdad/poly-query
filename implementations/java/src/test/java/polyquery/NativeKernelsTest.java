package polyquery;

import java.math.BigInteger;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.SplittableRandom;
import polyquery.engine.Engine;
import polyquery.ffi.NativeKernels;
import polyquery.ffi.NativeLoadException;

/**
 * Differential tests of the FFM binding of {@code libpqkernels}: every kernel against a plain Java
 * reference of the semantics in {@code pq_kernels.h}, on random data with NULLs, extreme values
 * and lengths around word and byte boundaries. Skipped (with a note) when the library has not
 * been built; its location is {@code -Dpolyquery.nativeKernels=PATH}, else the environment
 * variable {@code PQ_NATIVE_KERNELS}, else {@code ../../native-kernels/build/<arch>/libpqkernels.so}.
 */
public final class NativeKernelsTest {
    private static final int[] SIZES = {0, 1, 7, 8, 9, 63, 64, 65, 127, 200, 1000, 2048, 3001};
    private static boolean searched;
    private static NativeKernels kernels;

    private NativeKernelsTest() {
    }

    /** The library for tests, or null if it is not available. */
    public static synchronized NativeKernels kernels() {
        if (!searched) {
            searched = true;
            String path = System.getProperty("polyquery.nativeKernels", System.getenv("PQ_NATIVE_KERNELS"));
            if (path == null) {
                String arch = System.getProperty("os.arch").equals("amd64") ? "x86_64" : System.getProperty("os.arch");
                path = "../../native-kernels/build/" + arch + "/libpqkernels.so";
            }
            if (Files.isRegularFile(Path.of(path))) {
                try {
                    kernels = NativeKernels.load(Path.of(path));
                } catch (NativeLoadException e) {
                    throw new AssertionError("cannot load " + path + ": " + e.getMessage());
                }
            } else {
                System.out.println("note: native kernel library not found (" + path + "); native tests skipped");
            }
        }
        return kernels;
    }

    private static long[] randomLongs(SplittableRandom r, int n) {
        long[] x = new long[n + 1];
        for (int i = 0; i < n; i++) {
            x[i] = switch (r.nextInt(8)) {
                case 0 -> Long.MAX_VALUE - r.nextInt(3);
                case 1 -> Long.MIN_VALUE + r.nextInt(3);
                case 2 -> r.nextLong();
                default -> r.nextInt(21) - 10;
            };
        }
        return x;
    }

    /** A random validity bitmap with garbage beyond n, or null (all valid). */
    private static long[] randomValidity(SplittableRandom r, int n) {
        if (r.nextInt(3) == 0) {
            return null;
        }
        long[] v = new long[(n + 63) / 64 + 1];
        for (int w = 0; w < v.length; w++) {
            v[w] = r.nextInt(4) == 0 ? -1L : r.nextLong();
        }
        return v;
    }

    private static boolean bit(long[] bits, int i) {
        return (bits[i >>> 6] >>> i & 1) != 0;
    }

    private static boolean valid(long[] v, int i) {
        return v == null || bit(v, i);
    }

    private static boolean holds(int op, long x, long a, long b) {
        return switch (op) {
            case NativeKernels.EQ -> x == a;
            case NativeKernels.NE -> x != a;
            case NativeKernels.LT -> x < a;
            case NativeKernels.LE -> x <= a;
            case NativeKernels.GT -> x > a;
            case NativeKernels.GE -> x >= a;
            default -> a <= x && x <= b;
        };
    }

    static void testFilterKernelsMatchReference() {
        NativeKernels k = kernels();
        if (k == null) {
            return;
        }
        SplittableRandom r = new SplittableRandom(1);
        for (int n : SIZES) {
            for (int round = 0; round < 4; round++) {
                long[] x = randomLongs(r, n);
                long[] v = randomValidity(r, n);
                for (int op = NativeKernels.EQ; op <= NativeKernels.BETWEEN; op++) {
                    long a = round == 3 ? Long.MIN_VALUE : r.nextInt(11) - 5;
                    long b = round == 3 ? Long.MAX_VALUE : a + r.nextInt(6);
                    int[] idx = new int[n + 1];
                    long[] bits = new long[(n + 63) / 64 + 1];
                    int count = k.filter(x, v, n, op, a, b, idx);
                    int bitCount = k.filterBitmap(x, v, n, op, a, b, bits);
                    int expected = 0;
                    for (int i = 0; i < n; i++) {
                        boolean t = valid(v, i) && holds(op, x[i], a, b);
                        if (t) {
                            Assert.eq(i, idx[expected]);
                            expected++;
                        }
                        Assert.eq(t, bit(bits, i));
                    }
                    Assert.eq(expected, count);
                    Assert.eq(expected, bitCount);
                    Assert.eq(expected, k.count(x, v, n, op, a, b));
                    for (int i = n; i < ((n + 7) & ~7); i++) {
                        Assert.check(!bit(bits, i), "trailing bits of the last byte are zero");
                    }
                }
                if (n > 0) {
                    long[] y = randomLongs(r, n);
                    y[0] = x[0];
                    for (int op = NativeKernels.EQ; op <= NativeKernels.GE; op++) {
                        long[] bits = new long[(n + 63) / 64 + 1];
                        int c = k.compare(x, y, n, op, bits);
                        int expected = 0;
                        for (int i = 0; i < n; i++) {
                            boolean t = holds(op, x[i], y[i], 0);
                            Assert.eq(t, bit(bits, i));
                            expected += t ? 1 : 0;
                        }
                        Assert.eq(expected, c);
                    }
                }
            }
        }
        boolean rejected = false;
        try {
            k.filter(new long[4], null, 4, 9, 0, 0, new int[4]);
        } catch (IllegalArgumentException e) {
            rejected = true;
        }
        Assert.check(rejected, "unknown operator rejected");
    }

    static void testSumMinMaxCountMatchReference() {
        NativeKernels k = kernels();
        if (k == null) {
            return;
        }
        SplittableRandom r = new SplittableRandom(2);
        BigInteger min = BigInteger.valueOf(Long.MIN_VALUE);
        BigInteger max = BigInteger.valueOf(Long.MAX_VALUE);
        for (int n : SIZES) {
            for (int round = 0; round < 6; round++) {
                long[] x = randomLongs(r, n);
                if (round == 5) { // overflow that cancels out is not an error
                    for (int i = 0; i < n; i++) {
                        x[i] = i % 2 == 0 ? Long.MAX_VALUE : Long.MIN_VALUE + 1;
                    }
                }
                long[] v = randomValidity(r, n);
                BigInteger exact = BigInteger.ZERO;
                long lo = Long.MAX_VALUE;
                long hi = Long.MIN_VALUE;
                int valid = 0;
                double dsum = 0;
                double[] d = new double[n + 1];
                double dlo = Double.MAX_VALUE;
                double dhi = -Double.MAX_VALUE;
                for (int i = 0; i < n; i++) {
                    d[i] = (x[i] % 1000) / 8.0;
                    if (valid(v, i)) {
                        exact = exact.add(BigInteger.valueOf(x[i]));
                        lo = Math.min(lo, x[i]);
                        hi = Math.max(hi, x[i]);
                        valid++;
                        dsum += d[i];
                        dlo = Math.min(dlo, d[i]);
                        dhi = Math.max(dhi, d[i]);
                    }
                }
                long[] out = new long[2];
                int status = k.sum(x, v, n, out);
                if (exact.compareTo(min) < 0 || exact.compareTo(max) > 0) {
                    Assert.eq(NativeKernels.OVERFLOW, status);
                } else {
                    Assert.eq(NativeKernels.OK, status);
                    Assert.eq(exact.longValue(), out[0]);
                }
                Assert.eq(valid, k.minMax(x, v, n, out));
                if (valid > 0) {
                    Assert.eq(lo, out[0]);
                    Assert.eq(hi, out[1]);
                }
                double[] dout = new double[2];
                Assert.eq(valid, k.minMax(d, v, n, dout));
                if (valid > 0) {
                    Assert.eq(dlo, dout[0]);
                    Assert.eq(dhi, dout[1]);
                }
                Assert.check(Math.abs(k.sum(d, v, n) - dsum) <= 1e-9 * (1 + Math.abs(dsum)), "double sum");
                if (v != null) {
                    Assert.eq(valid, k.popcount(v, n));
                }
            }
        }
    }

    static void testBitmapHashGatherMatchReference() {
        NativeKernels k = kernels();
        if (k == null) {
            return;
        }
        SplittableRandom r = new SplittableRandom(3);
        for (int n : SIZES) {
            int words = (n + 63) / 64 + 1;
            long[] a = new long[words];
            long[] b = new long[words];
            for (int w = 0; w < words; w++) {
                a[w] = r.nextLong();
                b[w] = r.nextLong();
            }
            int nbytes = (n + 7) / 8;
            long[] and = new long[words];
            long[] or = new long[words];
            long[] andNot = new long[words];
            k.and(a, b, and, nbytes);
            k.or(a, b, or, nbytes);
            k.andNot(a, b, andNot, nbytes);
            int pop = 0;
            for (int i = 0; i < nbytes * 8; i++) {
                Assert.eq(bit(a, i) && bit(b, i), bit(and, i));
                Assert.eq(bit(a, i) || bit(b, i), bit(or, i));
                Assert.eq(bit(a, i) && !bit(b, i), bit(andNot, i));
            }
            for (int i = 0; i < n; i++) {
                pop += bit(a, i) ? 1 : 0;
            }
            Assert.eq(pop, k.popcount(a, n));
            long[] aliased = a.clone(); // out may alias an input
            k.and(aliased, b, aliased, nbytes);
            for (int i = 0; i < nbytes * 8; i++) {
                Assert.eq(bit(and, i), bit(aliased, i));
            }

            long[] x = randomLongs(r, n);
            long[] h = new long[n + 1];
            long seed = r.nextLong();
            k.hash(x, n, seed, h);
            for (int i = 0; i < n; i++) {
                Assert.eq(NativeKernels.fmix64(x[i] ^ seed), h[i]);
            }
            int[] idx = new int[n + 1];
            for (int j = 0; j < n; j++) {
                idx[j] = r.nextInt(n);
            }
            long[] g = new long[n + 1];
            k.gather(x, idx, n, g);
            double[] d = new double[n + 1];
            double[] dg = new double[n + 1];
            for (int i = 0; i < n; i++) {
                d[i] = x[i] / 3.0;
            }
            k.gather(d, idx, n, dg);
            for (int j = 0; j < n; j++) {
                Assert.eq(x[idx[j]], g[j]);
                Assert.eq(d[idx[j]], dg[j]);
            }
        }
    }

    static void testGroupSumMatchesReference() {
        NativeKernels k = kernels();
        if (k == null) {
            return;
        }
        SplittableRandom r = new SplittableRandom(4);
        for (int n : SIZES) {
            for (int round = 0; round < 4; round++) {
                int ngroups = 1 + r.nextInt(round == 0 ? 3 : 50);
                long[] x = randomLongs(r, n);
                if (round == 1) {
                    for (int i = 0; i < n; i++) {
                        x[i] = r.nextInt(1000);
                    }
                }
                long[] v = randomValidity(r, n);
                int[] gids = new int[n + 1];
                for (int i = 0; i < n; i++) {
                    gids[i] = r.nextInt(ngroups);
                }
                long[] sums = new long[ngroups];
                long[] counts = new long[ngroups];
                for (int g = 0; g < ngroups; g++) {
                    sums[g] = round == 2 ? Long.MAX_VALUE - g : g;
                    counts[g] = g;
                }
                long[] before = sums.clone();
                long[] wrapped = sums.clone();
                long[] expectedCounts = counts.clone();
                BigInteger[] exact = new BigInteger[ngroups];
                for (int g = 0; g < ngroups; g++) {
                    exact[g] = BigInteger.valueOf(sums[g]);
                }
                for (int i = 0; i < n; i++) {
                    if (valid(v, i)) {
                        wrapped[gids[i]] += x[i];
                        expectedCounts[gids[i]]++;
                        exact[gids[i]] = exact[gids[i]].add(BigInteger.valueOf(x[i]));
                    }
                }
                int status = k.groupSum(gids, x, v, n, sums, counts, ngroups);
                Assert.check(status == NativeKernels.OK || status == NativeKernels.OVERFLOW, "status " + status);
                Assert.eq(Arrays.toString(wrapped), Arrays.toString(sums));
                Assert.eq(Arrays.toString(expectedCounts), Arrays.toString(counts));
                if (status == NativeKernels.OK) {
                    for (int g = 0; g < ngroups; g++) {
                        Assert.eq(exact[g], BigInteger.valueOf(sums[g]));
                    }
                }
                if (round == 1) {
                    Assert.eq(NativeKernels.OK, status);
                }
                if (n > 0 && round == 3) { // an out-of-range group id leaves the outputs untouched
                    int i = r.nextInt(n);
                    gids[i] = ngroups;
                    long[] s2 = before.clone();
                    int st = k.groupSum(gids, x, null, n, s2, null, ngroups);
                    Assert.eq(NativeKernels.EINVAL, st);
                    Assert.eq(Arrays.toString(before), Arrays.toString(s2));
                }
            }
        }
    }

    /** Queries whose vectorized execution runs native kernels on the Phase5Test tables. */
    private static final String[] NATIVE_QUERIES = {
        "SELECT COUNT(*), SUM(id), MIN(val), MAX(val), COUNT(val), AVG(val) FROM t WHERE grp BETWEEN 2 AND 9",
        // never TRUE, NULL where val is NULL: the later conjunct still runs (and fails) on those rows
        "SELECT id FROM t WHERE val > 100 AND 10 / (grp - 4) > 0",
        "SELECT id FROM t WHERE val > 100 AND id > 0 AND 10 / (grp - 4) > 0",
        "SELECT id, val FROM t WHERE val >= grp AND day BETWEEN DATE '2024-01-05' AND DATE '2024-01-20'"
                + " AND grp IS NOT NULL",
        "SELECT COUNT(*), MIN(id), MAX(day) FROM t WHERE grp IS NULL OR val IS NULL",
        "SELECT COUNT(*) FROM t WHERE val IS NOT NULL AND val < 0 AND flag",
        "SELECT COUNT(*) FROM t WHERE 3 < val AND id <> 17 AND amt > 1.5",
        "SELECT grp, SUM(CASE WHEN id % 2 = 0 THEN 9223372036854775000 ELSE -9223372036854775000 END),"
                + " COUNT(*) FROM t GROUP BY grp",
        "SELECT SUM(CASE WHEN id % 2 = 0 THEN 9223372036854775000 ELSE -9223372036854775000 END) FROM t",
        "SELECT SUM(CASE WHEN id < 3 THEN 9223372036854775000 ELSE 1 END) FROM t WHERE id < 300",
        "SELECT grp, SUM(9223372036854775000 + id - id) FROM t GROUP BY grp",
        "SELECT flag, MIN(day), MAX(day), MIN(amt), MAX(amt), SUM(amt), AVG(amt), COUNT(grp) FROM t GROUP BY flag",
        "SELECT MIN(amt * -1.0), MAX(val * 1.0), MIN(id), MAX(day), SUM(val) FROM t WHERE id > 5",
        "SELECT DISTINCT val FROM t",
        "SELECT val, COUNT(*) FROM t WHERE id BETWEEN 10 AND 500 GROUP BY val",
        "SELECT name, COUNT(*) FROM t GROUP BY name",
        "SELECT t.id, d.label FROM t JOIN d ON d.label = t.name OR d.grp = t.grp WHERE t.id < 50 ORDER BY 1, 2",
    };

    static void testEndToEndAgreesWithAndWithoutNative() {
        NativeKernels k = kernels();
        if (k == null) {
            return;
        }
        Engine e = Phase5Test.engine(k);
        String[] all = new String[Phase5Test.QUERIES.length + NATIVE_QUERIES.length];
        System.arraycopy(Phase5Test.QUERIES, 0, all, 0, Phase5Test.QUERIES.length);
        System.arraycopy(NATIVE_QUERIES, 0, all, Phase5Test.QUERIES.length, NATIVE_QUERIES.length);
        Phase5Test.checkAllCombinations(e, all, true);
        System.setProperty("polyquery.batchSize", "13");
        System.setProperty("polyquery.morselRows", "37");
        try {
            Phase5Test.checkAllCombinations(Phase5Test.engine(k), all, true);
        } finally {
            System.clearProperty("polyquery.batchSize");
            System.clearProperty("polyquery.morselRows");
        }
    }

    static void testArgumentsAreChecked() {
        NativeKernels k = kernels();
        if (k == null) {
            return;
        }
        boolean rejected = false;
        try {
            k.sum(new long[3], null, 4, new long[1]);
        } catch (IndexOutOfBoundsException e) {
            rejected = true;
        }
        Assert.check(rejected, "short data array rejected");
        rejected = false;
        try {
            k.filter(new long[100], new long[1], 100, NativeKernels.EQ, 0, 0, new int[100]);
        } catch (IndexOutOfBoundsException e) {
            rejected = true;
        }
        Assert.check(rejected, "short validity bitmap rejected");
    }
}
