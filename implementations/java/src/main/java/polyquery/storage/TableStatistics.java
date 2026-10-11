package polyquery.storage;

import java.util.BitSet;
import java.util.List;
import polyquery.types.DataType;
import polyquery.types.Values;

/**
 * Per-table statistics (indexes-and-planning.md §3): row count plus, per column, null count,
 * min, max and distinct count. Column statistics are computed on first use and cached; the
 * object is shared by all snapshots of a table that share its data.
 */
public final class TableStatistics {
    private final TableData data;
    private final List<ColumnSchema> schema;
    private final ColumnStats[] columns;

    public TableStatistics(TableData data, List<ColumnSchema> schema) {
        this.data = data;
        this.schema = schema;
        this.columns = new ColumnStats[schema.size()];
    }

    public long rowCount() {
        return data.rowCount();
    }

    public ColumnStats column(int i) {
        synchronized (columns) {
            if (columns[i] != null) {
                return columns[i];
            }
        }
        ColumnStats s = compute(i);
        synchronized (columns) {
            columns[i] = s;
        }
        return s;
    }

    private ColumnStats compute(int column) {
        Accumulator acc = new Accumulator(schema.get(column).type());
        for (int g = 0; g < data.groupCount(); g++) {
            ColumnVector v = data.chunk(g, column);
            int n = data.groupSize(g);
            if (v instanceof ColumnVector.LongVector c) {
                acc.longs(c.values(), c.nulls(), n);
            } else if (v instanceof ColumnVector.IntVector c) {
                acc.ints(c.values(), c.nulls(), n);
            } else if (v instanceof ColumnVector.DoubleVector c) {
                acc.doubles(c.values(), c.nulls(), n);
            } else if (v instanceof ColumnVector.DictStringVector c) {
                acc.dictionary(c, n);
            } else {
                acc.values(v, n);
            }
        }
        return new ColumnStats(acc.nulls, acc.distinct.count(), acc.min, acc.max);
    }

    /**
     * Null count, min, max and distinct count of one column. The typed loops work on the chunks'
     * primitive arrays (no boxing per value: only each chunk's min and max are boxed and compared
     * with {@link Values#compare}); dictionary-encoded strings visit each dictionary entry once.
     * The result is the same as feeding every boxed value to {@link #offer}.
     */
    private static final class Accumulator {
        private final DataType type;
        final DistinctCounter distinct = new DistinctCounter();
        long nulls;
        Object min;
        Object max;

        Accumulator(DataType type) {
            this.type = type;
        }

        /** Min/max update with a non-null value (first of equal values kept). */
        void offer(Object x) {
            if (min == null || Values.compare(x, min, type) < 0) {
                min = x;
            }
            if (max == null || Values.compare(x, max, type) > 0) {
                max = x;
            }
        }

        void longs(long[] values, BitSet nullBits, int n) {
            long lo = Long.MAX_VALUE;
            long hi = Long.MIN_VALUE;
            int seen = 0;
            for (int i = 0; i < n; i++) {
                if (nullBits.get(i)) {
                    nulls++;
                    continue;
                }
                long x = values[i];
                distinct.addLong(x);
                lo = Math.min(lo, x);
                hi = Math.max(hi, x);
                seen++;
            }
            if (seen > 0) {
                offer(lo);
                offer(hi);
            }
        }

        void ints(int[] values, BitSet nullBits, int n) {
            int lo = Integer.MAX_VALUE;
            int hi = Integer.MIN_VALUE;
            int seen = 0;
            for (int i = 0; i < n; i++) {
                if (nullBits.get(i)) {
                    nulls++;
                    continue;
                }
                int x = values[i];
                distinct.addLong(x);
                lo = Math.min(lo, x);
                hi = Math.max(hi, x);
                seen++;
            }
            if (seen > 0) {
                offer(lo);
                offer(hi);
            }
        }

        void doubles(double[] values, BitSet nullBits, int n) {
            double lo = 0;
            double hi = 0;
            int seen = 0;
            for (int i = 0; i < n; i++) {
                if (nullBits.get(i)) {
                    nulls++;
                    continue;
                }
                double x = values[i] == 0.0 ? 0.0 : values[i]; // -0.0 counts as 0.0
                distinct.addLong(Double.doubleToLongBits(x));
                if (seen++ == 0) {
                    lo = x;
                    hi = x;
                } else {
                    lo = x < lo ? x : lo;
                    hi = x > hi ? x : hi;
                }
            }
            if (seen > 0) {
                offer(lo);
                offer(hi);
            }
        }

        void dictionary(ColumnVector.DictStringVector c, int n) {
            String[] dict = c.dictionary();
            int[] codes = c.codes();
            BitSet nullBits = c.nulls();
            boolean[] used = new boolean[dict.length];
            for (int i = 0; i < n; i++) {
                if (nullBits.get(i)) {
                    nulls++;
                } else {
                    used[codes[i]] = true;
                }
            }
            for (int code = 0; code < dict.length; code++) {
                if (used[code]) {
                    distinct.add(dict[code]);
                    offer(dict[code]);
                }
            }
        }

        /** Any other chunk (strings, booleans, wide DECIMALs, row-layout views): boxed values. */
        void values(ColumnVector v, int n) {
            for (int i = 0; i < n; i++) {
                Object x = v.get(i);
                if (x == null) {
                    nulls++;
                    continue;
                }
                distinct.add(x);
                offer(x);
            }
        }
    }
}
