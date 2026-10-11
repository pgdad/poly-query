package polyquery.common;

import java.util.Arrays;

/**
 * Interns objects (strings, wide DECIMALs) to dense ids {@code 0, 1, 2, …} in first-seen order:
 * an open-addressing table of ids (linear probing) over an array of the values and their hash
 * codes, so neither lookups nor inserts box the id.
 */
public final class ObjectIds {
    private Object[] values = new Object[16];
    private int[] hashes = new int[16];
    /** Slot → id + 1 (0: empty). */
    private int[] table = new int[32];
    private int mask = 31;
    private int size;

    public int size() {
        return size;
    }

    /** The value with id {@code id}. */
    public Object get(int id) {
        return values[id];
    }

    private static int spread(int h) {
        return (h * 0x9E3779B9) ^ (h >>> 16);
    }

    /** Id of {@code v} (non-null), assigning the next id if it is new. */
    public int intern(Object v) {
        int h = v.hashCode();
        int s = spread(h) & mask;
        while (true) {
            int e = table[s];
            if (e == 0) {
                break;
            }
            int id = e - 1;
            if (hashes[id] == h && values[id].equals(v)) {
                return id;
            }
            s = (s + 1) & mask;
        }
        int id = size++;
        if (id == values.length) {
            values = Arrays.copyOf(values, id * 2);
            hashes = Arrays.copyOf(hashes, id * 2);
        }
        values[id] = v;
        hashes[id] = h;
        table[s] = id + 1;
        if (size * 2 > table.length) {
            rehash();
        }
        return id;
    }

    /** Id of {@code v} (non-null), or -1 if it was never interned. */
    public int lookup(Object v) {
        int h = v.hashCode();
        int s = spread(h) & mask;
        while (true) {
            int e = table[s];
            if (e == 0) {
                return -1;
            }
            int id = e - 1;
            if (hashes[id] == h && values[id].equals(v)) {
                return id;
            }
            s = (s + 1) & mask;
        }
    }

    private void rehash() {
        table = new int[table.length * 2];
        mask = table.length - 1;
        for (int id = 0; id < size; id++) {
            int s = spread(hashes[id]) & mask;
            while (table[s] != 0) {
                s = (s + 1) & mask;
            }
            table[s] = id + 1;
        }
    }
}
