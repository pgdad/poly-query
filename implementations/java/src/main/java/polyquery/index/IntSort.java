package polyquery.index;

/** Stable merge sort of primitive ints with a custom comparator (no boxing). */
final class IntSort {
    /** Comparator over ints. */
    interface IntComparator {
        int compare(int a, int b);
    }

    private IntSort() {
    }

    static void sort(int[] a, IntComparator cmp) {
        if (a.length < 2) {
            return;
        }
        int[] tmp = new int[a.length];
        mergeSort(a, tmp, 0, a.length, cmp);
    }

    private static void mergeSort(int[] a, int[] tmp, int from, int to, IntComparator cmp) {
        int n = to - from;
        if (n <= 24) {
            for (int i = from + 1; i < to; i++) {
                int v = a[i];
                int j = i - 1;
                while (j >= from && cmp.compare(a[j], v) > 0) {
                    a[j + 1] = a[j];
                    j--;
                }
                a[j + 1] = v;
            }
            return;
        }
        int mid = (from + to) >>> 1;
        mergeSort(a, tmp, from, mid, cmp);
        mergeSort(a, tmp, mid, to, cmp);
        if (cmp.compare(a[mid - 1], a[mid]) <= 0) {
            return;
        }
        System.arraycopy(a, from, tmp, from, n);
        int i = from;
        int j = mid;
        int k = from;
        while (i < mid && j < to) {
            a[k++] = cmp.compare(tmp[j], tmp[i]) < 0 ? tmp[j++] : tmp[i++];
        }
        while (i < mid) {
            a[k++] = tmp[i++];
        }
        while (j < to) {
            a[k++] = tmp[j++];
        }
    }
}
