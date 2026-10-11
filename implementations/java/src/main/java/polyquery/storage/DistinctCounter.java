package polyquery.storage;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

/**
 * Counts distinct values: exactly while the number of distinct values is small, then with a
 * HyperLogLog sketch (2^14 registers, about 1% standard error).
 *
 * <p>Numbers, dates, timestamps and booleans are counted by a {@code long} key ({@link #addLong})
 * in a primitive hash set, without boxing; strings and wide DECIMALs as objects. A column's
 * values all have one representation, so the two exact sets never hold the same value.
 */
public final class DistinctCounter {
    private static final int EXACT_LIMIT = 100_000;
    private static final int P = 14;
    private static final int M = 1 << P;
    /** Marks an empty slot of {@link #longSlots}; the key itself is tracked by {@link #hasEmptyKey}. */
    private static final long EMPTY = Long.MIN_VALUE;

    private boolean exact = true;
    private final Set<Object> objects = new HashSet<>();
    private long[] longSlots = newSlots(64);
    private int longCount;
    private boolean hasEmptyKey;
    private final byte[] registers = new byte[M];

    /**
     * Adds a non-null value (runtime representation; -0.0 must already be normalized). Values
     * with a {@code long} key ({@code Long}, {@code Integer}, {@code Double}, {@code Boolean}) are
     * counted like {@link #addLong} of that key.
     */
    public void add(Object v) {
        switch (v) {
            case Long l -> addLong(l);
            case Integer i -> addLong(i);
            case Double d -> addLong(Double.doubleToLongBits(d));
            case Boolean b -> addLong(b ? 1 : 0);
            default -> {
                if (exact && objects.add(v)) {
                    checkLimit();
                }
                register(mix(objectKey(v)));
            }
        }
    }

    /**
     * Adds a value by its {@code long} key: the value of an INT64, DECIMAL (unscaled) or TIMESTAMP,
     * the epoch day of a DATE, {@code Double.doubleToLongBits} of a FLOAT64 (with -0.0 normalized),
     * 1 / 0 for a BOOLEAN.
     */
    public void addLong(long key) {
        if (exact && addExact(key)) {
            checkLimit();
        }
        register(mix(key));
    }

    public long count() {
        if (exact) {
            return objects.size() + longCount;
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

    private void checkLimit() {
        if (objects.size() + longCount > EXACT_LIMIT) {
            exact = false;
            objects.clear();
            longSlots = null;
        }
    }

    private void register(long h) {
        int idx = (int) (h >>> (64 - P));
        int rank = Long.numberOfLeadingZeros((h << P) | (1L << (P - 1))) + 1;
        if (rank > registers[idx]) {
            registers[idx] = (byte) rank;
        }
    }

    // ---------------------------------------------------------------- exact set of long keys

    private static long[] newSlots(int capacity) {
        long[] slots = new long[capacity];
        Arrays.fill(slots, EMPTY);
        return slots;
    }

    private static int slot(long key, int mask) {
        return (int) (mix(key) & mask);
    }

    /** Adds a key to the exact set; true if it was new. */
    private boolean addExact(long key) {
        if (key == EMPTY) {
            if (hasEmptyKey) {
                return false;
            }
            hasEmptyKey = true;
            longCount++;
            return true;
        }
        long[] t = longSlots;
        int mask = t.length - 1;
        for (int s = slot(key, mask); ; s = (s + 1) & mask) {
            long x = t[s];
            if (x == key) {
                return false;
            }
            if (x == EMPTY) {
                t[s] = key;
                if (++longCount * 2 > t.length) {
                    rehash();
                }
                return true;
            }
        }
    }

    private void rehash() {
        long[] old = longSlots;
        long[] t = newSlots(old.length * 2);
        int mask = t.length - 1;
        for (long x : old) {
            if (x != EMPTY) {
                int s = slot(x, mask);
                while (t[s] != EMPTY) {
                    s = (s + 1) & mask;
                }
                t[s] = x;
            }
        }
        longSlots = t;
    }

    // ---------------------------------------------------------------- hashing

    private static long objectKey(Object v) {
        if (v instanceof String s) {
            long h = 0xcbf29ce484222325L;
            for (int i = 0; i < s.length(); i++) {
                h = (h ^ s.charAt(i)) * 0x100000001b3L;
            }
            return h;
        }
        if (v instanceof java.math.BigInteger b) {
            return b.longValue() * 31 + b.shiftRight(64).longValue();
        }
        return v.hashCode();
    }

    /** MurmurHash3 finalizer. */
    private static long mix(long x) {
        x ^= x >>> 33;
        x *= 0xff51afd7ed558ccdL;
        x ^= x >>> 33;
        x *= 0xc4ceb9fe1a85ec53L;
        x ^= x >>> 33;
        return x;
    }
}
