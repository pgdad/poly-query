package polyquery.storage;

import java.util.HashSet;
import java.util.Set;

/**
 * Counts distinct values: exactly while the number of distinct values is small, then with a
 * HyperLogLog sketch (2^14 registers, about 1% standard error).
 */
public final class DistinctCounter {
    private static final int EXACT_LIMIT = 100_000;
    private static final int P = 14;
    private static final int M = 1 << P;

    private Set<Object> exact = new HashSet<>();
    private final byte[] registers = new byte[M];

    /** Adds a non-null value (runtime representation; -0.0 must already be normalized). */
    public void add(Object v) {
        if (exact != null) {
            exact.add(v);
            if (exact.size() > EXACT_LIMIT) {
                exact = null;
            }
        }
        long h = hash(v);
        int idx = (int) (h >>> (64 - P));
        int rank = Long.numberOfLeadingZeros((h << P) | (1L << (P - 1))) + 1;
        if (rank > registers[idx]) {
            registers[idx] = (byte) rank;
        }
    }

    public long count() {
        if (exact != null) {
            return exact.size();
        }
        double sum = 0;
        int zeros = 0;
        for (byte r : registers) {
            sum += Math.scalb(1.0, -r);
            if (r == 0) {
                zeros++;
            }
        }
        double alpha = 0.7213 / (1 + 1.079 / M);
        double estimate = alpha * M * (double) M / sum;
        if (estimate <= 2.5 * M && zeros > 0) {
            estimate = M * Math.log((double) M / zeros);
        }
        return Math.round(estimate);
    }

    private static long hash(Object v) {
        long x = switch (v) {
            case Long l -> l;
            case Integer i -> i;
            case Double d -> Double.doubleToLongBits(d);
            case Boolean b -> b ? 1 : 0;
            case String s -> {
                long h = 0xcbf29ce484222325L;
                for (int i = 0; i < s.length(); i++) {
                    h = (h ^ s.charAt(i)) * 0x100000001b3L;
                }
                yield h;
            }
            default -> v.hashCode();
        };
        // MurmurHash3 finalizer.
        x ^= x >>> 33;
        x *= 0xff51afd7ed558ccdL;
        x ^= x >>> 33;
        x *= 0xc4ceb9fe1a85ec53L;
        x ^= x >>> 33;
        return x;
    }
}
