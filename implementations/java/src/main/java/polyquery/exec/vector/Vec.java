package polyquery.exec.vector;

import java.util.Arrays;
import polyquery.types.DataType;

/**
 * A mutable column vector of one batch: a primitive array (struct-of-arrays layout) plus an
 * optional null mask. Positions are batch positions; only the active positions of the batch
 * that produced the vector hold meaningful values. Vectors are owned by the operator or
 * expression that fills them and are reused from batch to batch (no per-batch allocation).
 *
 * <p>Physical representations ({@link Kind}): BOOLEAN (0/1), INT64, DECIMAL (unscaled), DATE
 * (days) and TIMESTAMP (micros) use {@code longs}; FLOAT64 uses {@code doubles}; STRING uses
 * {@code objects} or, when read from a dictionary-encoded column, {@code codes} into
 * {@code dict}. The kind of a STRING vector may change from batch to batch.
 */
public final class Vec {
    /** Physical representation. */
    public enum Kind { LONG, DOUBLE, OBJECT, DICT }

    final DataType type;
    Kind kind;
    long[] longs;
    double[] doubles;
    Object[] objects;
    int[] codes;
    String[] dict;
    /** {@code nulls[i]} = position i is NULL; meaningful only when {@link #hasNulls}. */
    boolean[] nulls;
    boolean hasNulls;

    public Vec(DataType type, int capacity) {
        this.type = type;
        this.kind = kindOf(type);
        ensure(capacity);
    }

    /** Representation used for values of {@code type} (STRING vectors may also be DICT). */
    public static Kind kindOf(DataType type) {
        return switch (type.kind()) {
            case BOOLEAN, INT64, DECIMAL, DATE, TIMESTAMP -> Kind.LONG;
            case FLOAT64 -> Kind.DOUBLE;
            case STRING, NULL -> Kind.OBJECT;
        };
    }

    public DataType type() {
        return type;
    }

    /** Makes room for positions {@code 0 .. capacity-1} (contents of a grown vector are lost). */
    void ensure(int capacity) {
        switch (kind) {
            case LONG -> {
                if (longs == null || longs.length < capacity) {
                    longs = new long[capacity];
                }
            }
            case DOUBLE -> {
                if (doubles == null || doubles.length < capacity) {
                    doubles = new double[capacity];
                }
            }
            case OBJECT -> {
                if (objects == null || objects.length < capacity) {
                    objects = new Object[capacity];
                }
            }
            case DICT -> {
                if (codes == null || codes.length < capacity) {
                    codes = new int[capacity];
                }
            }
        }
        if (nulls != null && nulls.length < capacity) {
            nulls = new boolean[capacity];
        }
    }

    /** Grows to at least {@code capacity} positions, keeping the contents (column stores). */
    void grow(int capacity) {
        switch (kind) {
            case LONG -> longs = Arrays.copyOf(longs, Math.max(capacity, longs.length));
            case DOUBLE -> doubles = Arrays.copyOf(doubles, Math.max(capacity, doubles.length));
            case OBJECT -> objects = Arrays.copyOf(objects, Math.max(capacity, objects.length));
            case DICT -> codes = Arrays.copyOf(codes, Math.max(capacity, codes.length));
        }
        if (nulls != null) {
            nulls = Arrays.copyOf(nulls, Math.max(capacity, nulls.length));
        }
    }

    /** Switches a STRING vector to the plain object representation. */
    void toObjects(int capacity) {
        kind = Kind.OBJECT;
        dict = null;
        ensure(capacity);
    }

    /** Switches a STRING vector to the dictionary representation over {@code dictionary}. */
    void toDict(String[] dictionary, int capacity) {
        kind = Kind.DICT;
        dict = dictionary;
        ensure(capacity);
    }

    /** Returns the null mask, allocated for at least {@code capacity} positions; sets {@link #hasNulls}. */
    boolean[] nullMask(int capacity) {
        if (nulls == null || nulls.length < capacity) {
            nulls = new boolean[Math.max(capacity, longs != null ? longs.length : 0)];
        }
        hasNulls = true;
        return nulls;
    }

    public boolean isNull(int i) {
        return hasNulls && nulls[i];
    }

    /** STRING value at a non-null position (either representation). */
    String string(int i) {
        return kind == Kind.DICT ? dict[codes[i]] : (String) objects[i];
    }

    /** Boxed runtime value (see {@link DataType}) at position {@code i}, or null. */
    public Object get(int i) {
        if (hasNulls && nulls[i]) {
            return null;
        }
        return switch (kind) {
            case LONG -> switch (type.kind()) {
                case BOOLEAN -> longs[i] != 0;
                case DATE -> (int) longs[i];
                default -> longs[i];
            };
            case DOUBLE -> doubles[i];
            case OBJECT -> objects[i];
            case DICT -> dict[codes[i]];
        };
    }

    /**
     * Stores a boxed runtime value (or null) at position {@code i}. The vector must be in a
     * non-dictionary representation and its null mask must have been prepared with
     * {@link #nullMask(int)} for this batch.
     */
    void set(int i, Object v) {
        if (v == null) {
            nulls[i] = true;
            if (kind == Kind.OBJECT) {
                objects[i] = null;
            }
            return;
        }
        nulls[i] = false;
        switch (kind) {
            case LONG -> longs[i] = switch (v) {
                case Boolean b -> b ? 1 : 0;
                case Integer n -> n;
                default -> (Long) v;
            };
            case DOUBLE -> doubles[i] = (Double) v;
            case OBJECT -> objects[i] = v;
            case DICT -> throw new IllegalStateException("cannot store into a dictionary vector");
        }
    }

    /** Copies position {@code from} of {@code src} (same type) to position {@code to}; null mask prepared. */
    void copyFrom(Vec src, int from, int to) {
        if (src.hasNulls && src.nulls[from]) {
            nulls[to] = true;
            if (kind == Kind.OBJECT) {
                objects[to] = null;
            }
            return;
        }
        nulls[to] = false;
        switch (kind) {
            case LONG -> longs[to] = src.longs[from];
            case DOUBLE -> doubles[to] = src.doubles[from];
            case OBJECT -> objects[to] = src.kind == Kind.DICT ? src.dict[src.codes[from]] : src.objects[from];
            case DICT -> throw new IllegalStateException("cannot store into a dictionary vector");
        }
    }

    /** A vector holding {@code value} at every position {@code 0 .. capacity-1}. */
    static Vec constant(DataType type, Object value, int capacity) {
        Vec v = new Vec(type, capacity);
        v.fill(value, capacity);
        return v;
    }

    /** Sets positions {@code 0 .. n-1} to {@code value}. */
    void fill(Object value, int n) {
        if (value == null) {
            Arrays.fill(nullMask(n), 0, n, true);
            if (kind == Kind.OBJECT) {
                Arrays.fill(objects, 0, n, null);
            }
            return;
        }
        hasNulls = false;
        switch (kind) {
            case LONG -> Arrays.fill(longs, 0, n, switch (value) {
                case Boolean b -> b ? 1L : 0L;
                case Integer x -> (long) x;
                default -> (Long) value;
            });
            case DOUBLE -> Arrays.fill(doubles, 0, n, (Double) value);
            case OBJECT -> Arrays.fill(objects, 0, n, value);
            case DICT -> throw new IllegalStateException("cannot fill a dictionary vector");
        }
    }
}
