package polyquery.storage;

import java.util.Arrays;
import java.util.BitSet;
import polyquery.types.DataType;

/**
 * Immutable, typed, column-oriented storage of one column. Values are exposed in the runtime
 * representation documented on {@link DataType}.
 */
public abstract sealed class ColumnVector {
    protected final DataType type;
    protected final int size;

    protected ColumnVector(DataType type, int size) {
        this.type = type;
        this.size = size;
    }

    public DataType type() {
        return type;
    }

    public int size() {
        return size;
    }

    public abstract boolean isNull(int row);

    /** Boxed value or {@code null}. */
    public abstract Object get(int row);

    /** Approximate heap footprint in bytes. */
    public abstract long estimatedBytes();

    public static Builder builder(DataType type, int capacity) {
        return new Builder(type, capacity);
    }

    /** INT64, DECIMAL (unscaled) and TIMESTAMP (micros). */
    public static final class LongVector extends ColumnVector {
        private final long[] values;
        private final BitSet nulls;

        LongVector(DataType type, long[] values, BitSet nulls, int size) {
            super(type, size);
            this.values = values;
            this.nulls = nulls;
        }

        public long getLong(int row) {
            return values[row];
        }

        @Override
        public boolean isNull(int row) {
            return nulls.get(row);
        }

        @Override
        public Object get(int row) {
            return nulls.get(row) ? null : values[row];
        }

        @Override
        public long estimatedBytes() {
            return 8L * size + size / 8;
        }
    }

    public static final class DoubleVector extends ColumnVector {
        private final double[] values;
        private final BitSet nulls;

        DoubleVector(DataType type, double[] values, BitSet nulls, int size) {
            super(type, size);
            this.values = values;
            this.nulls = nulls;
        }

        public double getDouble(int row) {
            return values[row];
        }

        @Override
        public boolean isNull(int row) {
            return nulls.get(row);
        }

        @Override
        public Object get(int row) {
            return nulls.get(row) ? null : values[row];
        }

        @Override
        public long estimatedBytes() {
            return 8L * size + size / 8;
        }
    }

    /** DATE (days since epoch). */
    public static final class IntVector extends ColumnVector {
        private final int[] values;
        private final BitSet nulls;

        IntVector(DataType type, int[] values, BitSet nulls, int size) {
            super(type, size);
            this.values = values;
            this.nulls = nulls;
        }

        public int getInt(int row) {
            return values[row];
        }

        @Override
        public boolean isNull(int row) {
            return nulls.get(row);
        }

        @Override
        public Object get(int row) {
            return nulls.get(row) ? null : values[row];
        }

        @Override
        public long estimatedBytes() {
            return 4L * size + size / 8;
        }
    }

    public static final class BooleanVector extends ColumnVector {
        private final BitSet values;
        private final BitSet nulls;

        BooleanVector(DataType type, BitSet values, BitSet nulls, int size) {
            super(type, size);
            this.values = values;
            this.nulls = nulls;
        }

        public boolean getBoolean(int row) {
            return values.get(row);
        }

        @Override
        public boolean isNull(int row) {
            return nulls.get(row);
        }

        @Override
        public Object get(int row) {
            return nulls.get(row) ? null : values.get(row);
        }

        @Override
        public long estimatedBytes() {
            return size / 4;
        }
    }

    public static final class StringVector extends ColumnVector {
        private final String[] values;

        StringVector(DataType type, String[] values, int size) {
            super(type, size);
            this.values = values;
        }

        @Override
        public boolean isNull(int row) {
            return values[row] == null;
        }

        @Override
        public Object get(int row) {
            return values[row];
        }

        @Override
        public long estimatedBytes() {
            long total = 8L * size;
            for (int i = 0; i < size; i++) {
                if (values[i] != null) {
                    total += 40 + values[i].length();
                }
            }
            return total;
        }
    }

    /**
     * Dictionary-encoded STRING column: each row stores a code into a table of distinct
     * strings (null rows are marked in the null bitmap; their codes are meaningless).
     */
    public static final class DictStringVector extends ColumnVector {
        private final String[] dictionary;
        private final int[] codes;
        private final BitSet nulls;

        DictStringVector(DataType type, String[] dictionary, int[] codes, BitSet nulls, int size) {
            super(type, size);
            this.dictionary = dictionary;
            this.codes = codes;
            this.nulls = nulls;
        }

        public int dictionarySize() {
            return dictionary.length;
        }

        public String dictionaryEntry(int code) {
            return dictionary[code];
        }

        public int code(int row) {
            return codes[row];
        }

        @Override
        public boolean isNull(int row) {
            return nulls.get(row);
        }

        @Override
        public Object get(int row) {
            return nulls.get(row) ? null : dictionary[codes[row]];
        }

        @Override
        public long estimatedBytes() {
            long total = 4L * size + size / 8;
            for (String s : dictionary) {
                total += 40 + s.length();
            }
            return total;
        }
    }

    /** Column {@code column} of a row-oriented table, viewed as a vector (no copy). */
    public static final class RowColumnView extends ColumnVector {
        private final Object[][] rows;
        private final int column;

        RowColumnView(DataType type, Object[][] rows, int column) {
            super(type, rows.length);
            this.rows = rows;
            this.column = column;
        }

        @Override
        public boolean isNull(int row) {
            return rows[row][column] == null;
        }

        @Override
        public Object get(int row) {
            return rows[row][column];
        }

        @Override
        public long estimatedBytes() {
            return 0;
        }
    }

    // ---------------------------------------------------------------- factories (null bitmap: set bit = NULL)

    public static ColumnVector ofLongs(DataType type, long[] values, BitSet nulls) {
        return new LongVector(type, values, nulls, values.length);
    }

    public static ColumnVector ofDoubles(double[] values, BitSet nulls) {
        return new DoubleVector(DataType.FLOAT64, values, nulls, values.length);
    }

    public static ColumnVector ofInts(DataType type, int[] values, BitSet nulls) {
        return new IntVector(type, values, nulls, values.length);
    }

    public static ColumnVector ofBooleans(BitSet values, BitSet nulls, int size) {
        return new BooleanVector(DataType.BOOLEAN, values, nulls, size);
    }

    /** STRING vector; null array elements are NULL. */
    public static ColumnVector ofStrings(String[] values) {
        return new StringVector(DataType.STRING, values, values.length);
    }

    public static ColumnVector ofDictionary(String[] dictionary, int[] codes, BitSet nulls) {
        return new DictStringVector(DataType.STRING, dictionary, codes, nulls, codes.length);
    }

    static ColumnVector rowView(DataType type, Object[][] rows, int column) {
        return new RowColumnView(type, rows, column);
    }

    /** Append-only builder producing an immutable vector. */
    public static final class Builder {
        private final DataType type;
        private int size;
        private long[] longs;
        private double[] doubles;
        private int[] ints;
        private String[] strings;
        private final BitSet bits = new BitSet();
        private final BitSet nulls = new BitSet();

        Builder(DataType type, int capacity) {
            this.type = type;
            int cap = Math.max(capacity, 16);
            switch (type.kind()) {
                case INT64, DECIMAL, TIMESTAMP -> longs = new long[cap];
                case FLOAT64 -> doubles = new double[cap];
                case DATE -> ints = new int[cap];
                case BOOLEAN -> {
                }
                default -> strings = new String[cap];
            }
        }

        private void grow() {
            int cap = capacity();
            if (size < cap) {
                return;
            }
            int n = cap + (cap >> 1) + 16;
            if (longs != null) {
                longs = Arrays.copyOf(longs, n);
            } else if (doubles != null) {
                doubles = Arrays.copyOf(doubles, n);
            } else if (ints != null) {
                ints = Arrays.copyOf(ints, n);
            } else if (strings != null) {
                strings = Arrays.copyOf(strings, n);
            }
        }

        private int capacity() {
            if (longs != null) {
                return longs.length;
            }
            if (doubles != null) {
                return doubles.length;
            }
            if (ints != null) {
                return ints.length;
            }
            if (strings != null) {
                return strings.length;
            }
            return Integer.MAX_VALUE;
        }

        public int size() {
            return size;
        }

        public void appendNull() {
            grow();
            nulls.set(size);
            size++;
        }

        /** Appends a value in runtime representation ({@code null} allowed). */
        public void append(Object v) {
            if (v == null) {
                appendNull();
                return;
            }
            grow();
            switch (type.kind()) {
                case INT64, DECIMAL, TIMESTAMP -> longs[size] = (Long) v;
                case FLOAT64 -> {
                    double d = (Double) v;
                    doubles[size] = d == 0.0 ? 0.0 : d;
                }
                case DATE -> ints[size] = (Integer) v;
                case BOOLEAN -> bits.set(size, (Boolean) v);
                default -> strings[size] = (String) v;
            }
            size++;
        }

        public ColumnVector build() {
            return switch (type.kind()) {
                case INT64, DECIMAL, TIMESTAMP -> new LongVector(type, Arrays.copyOf(longs, size), nulls, size);
                case FLOAT64 -> new DoubleVector(type, Arrays.copyOf(doubles, size), nulls, size);
                case DATE -> new IntVector(type, Arrays.copyOf(ints, size), nulls, size);
                case BOOLEAN -> new BooleanVector(type, bits, nulls, size);
                default -> new StringVector(type, Arrays.copyOf(strings, size), size);
            };
        }
    }
}
