package polyquery.exec.vector;

import java.util.Arrays;

/** An open-addressing hash set of {@code long} values (linear probing, keys stored inline). */
final class LongSet {
    /** Marks an empty slot; the value itself is tracked by {@link #hasEmptyValue}. */
    private static final long EMPTY = Long.MIN_VALUE;

    private long[] slots;
    private int mask;
    private int shift;
    private int size;
    private boolean hasEmptyValue;

    LongSet(int expected) {
        int cap = Integer.highestOneBit(Math.max(16, expected * 2 - 1)) << 1;
        allocate(cap);
    }

    private void allocate(int cap) {
        slots = new long[cap];
        Arrays.fill(slots, EMPTY);
        mask = cap - 1;
        shift = 64 - Integer.numberOfTrailingZeros(cap);
    }

    private int slot(long v) {
        return (int) ((v * 0x9E3779B97F4A7C15L) >>> shift);
    }

    int size() {
        return size;
    }

    /** Adds {@code v}; true if it was not present. */
    boolean add(long v) {
        if (v == EMPTY) {
            if (hasEmptyValue) {
                return false;
            }
            hasEmptyValue = true;
            size++;
            return true;
        }
        int s = slot(v);
        long[] t = slots;
        while (true) {
            long x = t[s];
            if (x == v) {
                return false;
            }
            if (x == EMPTY) {
                t[s] = v;
                if (++size * 2 > t.length) {
                    rehash();
                }
                return true;
            }
            s = (s + 1) & mask;
        }
    }

    boolean contains(long v) {
        if (v == EMPTY) {
            return hasEmptyValue;
        }
        int s = slot(v);
        long[] t = slots;
        while (true) {
            long x = t[s];
            if (x == v) {
                return true;
            }
            if (x == EMPTY) {
                return false;
            }
            s = (s + 1) & mask;
        }
    }

    private void rehash() {
        long[] old = slots;
        allocate(old.length * 2);
        for (long x : old) {
            if (x != EMPTY) {
                int s = slot(x);
                while (slots[s] != EMPTY) {
                    s = (s + 1) & mask;
                }
                slots[s] = x;
            }
        }
    }
}
