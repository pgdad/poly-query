package polyquery;

import java.nio.file.Path;
import java.util.SplittableRandom;
import java.util.function.IntSupplier;
import polyquery.ffi.NativeKernels;

/**
 * Micro-benchmark of the native kernels as the engine calls them — through the FFM binding, on
 * Java heap arrays — against the equivalent plain-Java loops of the vectorized engine, at a
 * batch size (2,048 rows) and a morsel size (65,536 rows). Prints ns per row (median of 15
 * timed runs). Development tool: {@code make bench-kernels NATIVE_LIB=...}.
 */
public final class KernelBench {
    private static long sink;

    private KernelBench() {
    }

    private static double nsPerRow(int n, IntSupplier body) {
        int iters = Math.max(1, 20_000_000 / n);
        for (int w = 0; w < 3; w++) {
            for (int i = 0; i < iters; i++) {
                sink += body.getAsInt();
            }
        }
        double[] runs = new double[15];
        for (int r = 0; r < runs.length; r++) {
            long t0 = System.nanoTime();
            for (int i = 0; i < iters; i++) {
                sink += body.getAsInt();
            }
            runs[r] = (System.nanoTime() - t0) / ((double) iters * n);
        }
        java.util.Arrays.sort(runs);
        return runs[runs.length / 2];
    }

    private static void row(String name, int n, IntSupplier nat, IntSupplier java) {
        int a = nat.getAsInt();
        int b = java.getAsInt();
        if (a != b) {
            throw new AssertionError(name + ": native " + a + " != java " + b);
        }
        double tn = nsPerRow(n, nat);
        double tj = nsPerRow(n, java);
        System.out.printf("| %s | %,d | %.3f | %.3f | %.1f× |%n", name, n, tj, tn, tj / tn);
    }

    public static void main(String[] args) throws Exception {
        NativeKernels k = NativeKernels.load(Path.of(args[0]));
        System.out.println("variant " + k.variant());
        System.out.println("| kernel | rows per call | Java ns/row | native ns/row | speed-up |");
        System.out.println("|---|---:|---:|---:|---:|");
        for (int n : new int[] {2048, 65536}) {
            SplittableRandom r = new SplittableRandom(42);
            long[] x = new long[n];
            long[] y = new long[n];
            int[] gids = new int[n];
            boolean[] nulls = new boolean[n];
            long[] validity = new long[(n + 63) / 64];
            for (int i = 0; i < n; i++) {
                x[i] = r.nextInt(1000);
                y[i] = r.nextInt(1000);
                gids[i] = r.nextInt(1000);
                nulls[i] = r.nextInt(4) == 0;
                if (!nulls[i]) {
                    validity[i >>> 6] |= 1L << i;
                }
            }
            int[] idx = new int[n];
            long[] bits = new long[(n + 63) / 64];
            long[] bits2 = new long[(n + 63) / 64];
            long[] out = new long[Math.max(2, n)];
            long[] r01 = new long[n];
            long[] sums = new long[1000];
            long[] counts = new long[1000];

            row("filter_i64 (x < 500 → selection)", n, () -> k.filter(x, null, n, NativeKernels.LT, 500, 0, idx), () -> {
                for (int i = 0; i < n; i++) { // the engine: 0/1 vector, then selection building
                    long d = x[i] - 500;
                    r01[i] = d >>> 63;
                }
                int m = 0;
                for (int i = 0; i < n; i++) {
                    idx[m] = i;
                    m += (int) r01[i];
                }
                return m;
            });
            row("filter_i64_bitmap + bitmap_and (2 conjuncts)", n, () -> {
                k.filterBitmap(x, null, n, NativeKernels.LT, 500, 0, bits);
                k.filterBitmap(y, null, n, NativeKernels.GE, 100, 0, bits2);
                k.and(bits, bits2, bits, (n + 7) / 8);
                return k.popcount(bits, n);
            }, () -> {
                int m = 0;
                for (int i = 0; i < n; i++) {
                    idx[m] = i;
                    m += x[i] < 500 ? 1 : 0;
                }
                int c = 0;
                for (int j = 0; j < m; j++) {
                    int i = idx[j];
                    idx[c] = i;
                    c += y[i] >= 100 ? 1 : 0;
                }
                return c;
            });
            row("sum_i64 (exact)", n, () -> {
                k.sum(x, null, n, out);
                return (int) out[0];
            }, () -> {
                long lo = 0;
                long hi = 0;
                for (int i = 0; i < n; i++) {
                    lo += x[i] & 0xFFFFFFFFL;
                    hi += x[i] >> 32;
                }
                return (int) ((hi << 32) + lo);
            });
            row("sum_i64 with validity (25% NULL)", n, () -> {
                k.sum(x, validity, n, out);
                return (int) out[0];
            }, () -> {
                long s = 0;
                for (int i = 0; i < n; i++) {
                    if (!nulls[i]) {
                        long v = x[i];
                        long t = s + v;
                        if (((s ^ t) & (v ^ t)) < 0) {
                            throw new ArithmeticException();
                        }
                        s = t;
                    }
                }
                return (int) s;
            });
            row("minmax_i64", n, () -> {
                k.minMax(x, null, n, out);
                return (int) (out[0] + out[1]);
            }, () -> {
                long lo = Long.MAX_VALUE;
                long hi = Long.MIN_VALUE;
                for (int i = 0; i < n; i++) {
                    lo = Math.min(lo, x[i]);
                    hi = Math.max(hi, x[i]);
                }
                return (int) (lo + hi);
            });
            row("bitmap_popcount (COUNT(x))", n, () -> k.popcount(validity, n), () -> {
                int c = 0;
                for (int i = 0; i < n; i++) {
                    c += nulls[i] ? 0 : 1;
                }
                return c;
            });
            row("hash_i64", n, () -> {
                k.hash(x, n, 7, out);
                return (int) out[n - 1];
            }, () -> {
                for (int i = 0; i < n; i++) {
                    out[i] = NativeKernels.fmix64(x[i] ^ 7);
                }
                return (int) out[n - 1];
            });
            row("group_sum_i64 (1,000 groups)", n, () -> k.groupSum(gids, x, null, n, sums, counts, 1000), () -> {
                for (int i = 0; i < n; i++) {
                    int g = gids[i];
                    long v = x[i];
                    counts[g]++;
                    long s = sums[g];
                    long t = s + v;
                    if (((s ^ t) & (v ^ t)) < 0) {
                        return 1;
                    }
                    sums[g] = t;
                }
                return 0;
            });
            int m = k.filter(x, null, n, NativeKernels.LT, 500, 0, idx);
            row("gather_i64 (selection of ~50%)", n, () -> {
                k.gather(x, idx, m, out);
                return (int) out[m - 1];
            }, () -> {
                for (int j = 0; j < m; j++) {
                    out[j] = x[idx[j]];
                }
                return (int) out[m - 1];
            });
        }
        System.out.println("(checksum " + sink + ")");
    }
}
