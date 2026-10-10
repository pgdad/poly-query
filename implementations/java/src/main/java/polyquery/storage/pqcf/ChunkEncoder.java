package polyquery.storage.pqcf;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import polyquery.types.DataType;
import polyquery.types.TypeKind;
import polyquery.types.Values;

/** Encodes the values of one column for one row group into a PQCF column chunk (pqcf-v1.md §3). */
final class ChunkEncoder {
    /** An encoded chunk plus the metadata describing it. */
    record EncodedChunk(byte[] bytes, Encoding encoding, int nullCount, Object min, Object max) {
    }

    private ChunkEncoder() {
    }

    /** @param values runtime values of the chunk's rows (null = NULL) */
    static EncodedChunk encode(DataType type, Object[] values, SaveEncoding mode) {
        int n = values.length;
        int nullCount = 0;
        Object min = null;
        Object max = null;
        for (Object v : values) {
            if (v == null) {
                nullCount++;
            } else if (type.kind() != TypeKind.STRING) {
                if (min == null || Values.compare(v, min, type) < 0) {
                    min = v;
                }
                if (max == null || Values.compare(v, max, type) > 0) {
                    max = v;
                }
            }
        }
        Encoding encoding = choose(type, values, mode);
        ByteSink out = new ByteSink(n * 8 + 64);
        if (nullCount > 0) {
            out.putBitmap(i -> values[i] != null, n);
        }
        switch (encoding) {
            case PLAIN -> writePlain(out, type, values);
            case DICT -> writeDict(out, values);
            case RLE -> writeRle(out, type, values);
        }
        return new EncodedChunk(out.toByteArray(), encoding, nullCount, min, max);
    }

    private static Encoding choose(DataType type, Object[] values, SaveEncoding mode) {
        int n = values.length;
        return switch (mode) {
            case PLAIN -> Encoding.PLAIN;
            case DICT -> Encoding.DICT.appliesTo(type) ? Encoding.DICT : Encoding.PLAIN;
            case RLE -> Encoding.RLE.appliesTo(type) ? Encoding.RLE : Encoding.PLAIN;
            case AUTO -> {
                if (n == 0) {
                    yield Encoding.PLAIN;
                }
                if (Encoding.RLE.appliesTo(type) && countRuns(longValues(type, values)) < n / 4) {
                    yield Encoding.RLE;
                }
                if (Encoding.DICT.appliesTo(type) && countDistinct(values, n / 2) < n / 2) {
                    yield Encoding.DICT;
                }
                yield Encoding.PLAIN;
            }
        };
    }

    // ---------------------------------------------------------------- PLAIN

    private static void writePlain(ByteSink out, DataType type, Object[] values) {
        int n = values.length;
        switch (type.kind()) {
            case BOOLEAN -> out.putBitmap(i -> Boolean.TRUE.equals(values[i]), n);
            case INT64, DECIMAL, TIMESTAMP -> {
                for (Object v : values) {
                    out.putLong(v == null ? 0 : (Long) v);
                }
            }
            case FLOAT64 -> {
                for (Object v : values) {
                    double d = v == null ? 0.0 : (Double) v;
                    out.putLong(Double.doubleToRawLongBits(d == 0.0 ? 0.0 : d));
                }
            }
            case DATE -> {
                for (Object v : values) {
                    out.putInt(v == null ? 0 : (Integer) v);
                }
            }
            default -> writeStrings(out, toStrings(values));
        }
    }

    /** {@code (n+1)} u32 offsets followed by the concatenated UTF-8 bytes. */
    private static void writeStrings(ByteSink out, String[] strings) {
        byte[][] bytes = ByteSink.utf8(strings);
        long offset = 0;
        out.putInt(0);
        for (byte[] b : bytes) {
            offset += b.length;
            if (offset > 0xFFFF_FFFFL) {
                throw new IllegalStateException("string data of a chunk exceeds 4 GiB");
            }
            out.putInt((int) offset);
        }
        for (byte[] b : bytes) {
            out.putBytes(b);
        }
    }

    private static String[] toStrings(Object[] values) {
        String[] out = new String[values.length];
        for (int i = 0; i < out.length; i++) {
            out[i] = (String) values[i];
        }
        return out;
    }

    // ---------------------------------------------------------------- DICT

    private static void writeDict(ByteSink out, Object[] values) {
        Map<String, Integer> codes = new HashMap<>();
        List<String> dict = new ArrayList<>();
        int[] rowCodes = new int[values.length];
        for (int i = 0; i < values.length; i++) {
            String s = (String) values[i];
            if (s == null) {
                continue;
            }
            Integer code = codes.get(s);
            if (code == null) {
                code = dict.size();
                codes.put(s, code);
                dict.add(s);
            }
            rowCodes[i] = code;
        }
        out.putInt(dict.size());
        writeStrings(out, dict.toArray(new String[0]));
        for (int c : rowCodes) {
            out.putInt(c);
        }
    }

    private static int countDistinct(Object[] values, int stopAt) {
        Set<Object> seen = new HashSet<>();
        for (Object v : values) {
            if (v != null && seen.add(v) && seen.size() >= stopAt) {
                break;
            }
        }
        return seen.size();
    }

    // ---------------------------------------------------------------- RLE

    /**
     * Slot values widened to i64. NULL slots take the value of the preceding non-null slot (or
     * the first non-null value) so that they extend runs instead of breaking them.
     */
    private static long[] longValues(DataType type, Object[] values) {
        long[] out = new long[values.length];
        long fill = 0;
        for (Object v : values) {
            if (v != null) {
                fill = widen(type, v);
                break;
            }
        }
        for (int i = 0; i < values.length; i++) {
            if (values[i] != null) {
                fill = widen(type, values[i]);
            }
            out[i] = fill;
        }
        return out;
    }

    private static long widen(DataType type, Object v) {
        return switch (type.kind()) {
            case BOOLEAN -> ((Boolean) v) ? 1 : 0;
            case DATE -> (Integer) v;
            default -> (Long) v;
        };
    }

    private static int countRuns(long[] slots) {
        int runs = 0;
        for (int i = 0; i < slots.length; i++) {
            if (i == 0 || slots[i] != slots[i - 1]) {
                runs++;
            }
        }
        return runs;
    }

    private static void writeRle(ByteSink out, DataType type, Object[] values) {
        long[] slots = longValues(type, values);
        out.putInt(countRuns(slots));
        int i = 0;
        while (i < slots.length) {
            int j = i + 1;
            while (j < slots.length && slots[j] == slots[i]) {
                j++;
            }
            out.putLong(slots[i]);
            out.putInt(j - i);
            i = j;
        }
    }
}
