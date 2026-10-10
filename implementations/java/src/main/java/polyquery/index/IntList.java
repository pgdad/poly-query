package polyquery.index;

import java.util.Arrays;

/** Growable list of primitive ints. */
final class IntList {
    private int[] values;
    private int size;

    IntList(int capacity) {
        values = new int[Math.max(1, capacity)];
    }

    void add(int v) {
        if (size == values.length) {
            values = Arrays.copyOf(values, size * 2);
        }
        values[size++] = v;
    }

    void addAll(int[] vs) {
        for (int v : vs) {
            add(v);
        }
    }

    int size() {
        return size;
    }

    int[] toArray() {
        return Arrays.copyOf(values, size);
    }

    /** Sorted, duplicate-free copy. */
    int[] toSortedDistinct() {
        int[] out = toArray();
        Arrays.sort(out);
        int n = 0;
        for (int i = 0; i < out.length; i++) {
            if (i == 0 || out[i] != out[i - 1]) {
                out[n++] = out[i];
            }
        }
        return n == out.length ? out : Arrays.copyOf(out, n);
    }
}
