package polyquery.storage.pqcf;

import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.BitSet;
import java.util.zip.CRC32;
import polyquery.storage.ColumnVector;
import polyquery.types.DataType;
import polyquery.types.DateTimes;
import polyquery.types.Decimals;

/**
 * Verifies and decodes one PQCF column chunk (pqcf-v1.md §3–§4). Every structural or value
 * violation is reported as {@code STORAGE_CORRUPT}; the decoder never reads outside the chunk.
 */
final class ChunkDecoder {
    private static final ValueLayout.OfInt U32 = ValueLayout.JAVA_INT_UNALIGNED.withOrder(ByteOrder.LITTLE_ENDIAN);
    private static final ValueLayout.OfLong I64 = ValueLayout.JAVA_LONG_UNALIGNED.withOrder(ByteOrder.LITTLE_ENDIAN);
    private static final long MIN_MICROS = DateTimes.MIN_DAY * DateTimes.MICROS_PER_DAY;
    private static final long MAX_MICROS = (DateTimes.MAX_DAY + 1L) * DateTimes.MICROS_PER_DAY - 1;

    private final MemorySegment chunk;
    private final DataType type;
    private final int n;
    private final int nullCount;
    private final BitSet nulls = new BitSet();
    private long pos;

    private ChunkDecoder(MemorySegment chunk, DataType type, int n, int nullCount) {
        this.chunk = chunk;
        this.type = type;
        this.n = n;
        this.nullCount = nullCount;
    }

    /** Verifies the CRC of the chunk described by {@code meta} and decodes its {@code n} values. */
    static ColumnVector decode(MemorySegment file, FileMeta.ChunkMeta meta, DataType type, int n) {
        MemorySegment chunk = file.asSlice(meta.offset(), meta.length());
        CRC32 crc = new CRC32();
        crc.update(chunk.asByteBuffer());
        if (crc.getValue() != meta.crc32()) {
            throw PqcfReader.corrupt("column chunk checksum mismatch at offset " + meta.offset());
        }
        ChunkDecoder d = new ChunkDecoder(chunk, type, n, meta.nullCount());
        d.readValidity();
        ColumnVector v = switch (meta.encoding()) {
            case PLAIN -> d.plain();
            case DICT -> d.dict();
            case RLE -> d.rle();
        };
        if (d.pos != chunk.byteSize()) {
            throw PqcfReader.corrupt("column chunk size does not match its contents");
        }
        return v;
    }

    // ---------------------------------------------------------------- primitives

    private void need(long bytes) {
        if (bytes < 0 || pos + bytes > chunk.byteSize()) {
            throw PqcfReader.corrupt("column chunk is truncated");
        }
    }

    private long u32() {
        need(4);
        long v = Integer.toUnsignedLong(chunk.get(U32, pos));
        pos += 4;
        return v;
    }

    private long i64() {
        need(8);
        long v = chunk.get(I64, pos);
        pos += 8;
        return v;
    }

    private int i32() {
        need(4);
        int v = chunk.get(U32, pos);
        pos += 4;
        return v;
    }

    /** Reads an LSB-first bitmap of {@code n} bits (trailing bits ignored). */
    private BitSet bitmap() {
        long bytes = (n + 7L) / 8;
        need(bytes);
        BitSet out = BitSet.valueOf(chunk.asSlice(pos, bytes).toArray(ValueLayout.JAVA_BYTE));
        out.clear(n, Math.max(n, out.length()));
        pos += bytes;
        return out;
    }

    private void readValidity() {
        if (nullCount == 0) {
            return;
        }
        BitSet valid = bitmap();
        if (n - valid.cardinality() != nullCount) {
            throw PqcfReader.corrupt("validity bitmap does not match null_count");
        }
        nulls.set(0, n);
        nulls.andNot(valid);
    }

    // ---------------------------------------------------------------- value checks

    private long checkLong(long v) {
        switch (type.kind()) {
            case DECIMAL -> {
                if (!Decimals.fitsPrecision(v, type.precision())) {
                    throw PqcfReader.corrupt("DECIMAL value exceeds the column precision");
                }
            }
            case TIMESTAMP -> {
                if (v < MIN_MICROS || v > MAX_MICROS) {
                    throw PqcfReader.corrupt("TIMESTAMP value out of range");
                }
            }
            case DATE -> {
                if (v < DateTimes.MIN_DAY || v > DateTimes.MAX_DAY) {
                    throw PqcfReader.corrupt("DATE value out of range");
                }
            }
            case BOOLEAN -> {
                if (v != 0 && v != 1) {
                    throw PqcfReader.corrupt("BOOLEAN run value is not 0 or 1");
                }
            }
            default -> {
            }
        }
        return v;
    }

    // ---------------------------------------------------------------- PLAIN

    private ColumnVector plain() {
        switch (type.kind()) {
            case BOOLEAN -> {
                BitSet values = bitmap();
                values.andNot(nulls);
                return ColumnVector.ofBooleans(values, nulls, n);
            }
            case INT64, DECIMAL, TIMESTAMP -> {
                need(8L * n);
                long[] values = new long[n];
                for (int i = 0; i < n; i++) {
                    long v = i64();
                    values[i] = nulls.get(i) ? 0 : checkLong(v);
                }
                return ColumnVector.ofLongs(type, values, nulls);
            }
            case FLOAT64 -> {
                need(8L * n);
                double[] values = new double[n];
                for (int i = 0; i < n; i++) {
                    double d = Double.longBitsToDouble(i64());
                    if (nulls.get(i)) {
                        continue;
                    }
                    if (!Double.isFinite(d)) {
                        throw PqcfReader.corrupt("non-finite FLOAT64 value");
                    }
                    values[i] = d == 0.0 ? 0.0 : d;
                }
                return ColumnVector.ofDoubles(values, nulls);
            }
            case DATE -> {
                need(4L * n);
                int[] values = new int[n];
                for (int i = 0; i < n; i++) {
                    int v = i32();
                    values[i] = nulls.get(i) ? 0 : (int) checkLong(v);
                }
                return ColumnVector.ofInts(type, values, nulls);
            }
            default -> {
                String[] values = strings(n, nulls);
                return ColumnVector.ofStrings(values);
            }
        }
    }

    /**
     * Reads {@code count} STRING values in offsets + bytes form; entries flagged in
     * {@code skip} (may be null) are not decoded and come back as null.
     */
    private String[] strings(int count, BitSet skip) {
        need(4L * (count + 1));
        long[] offsets = new long[count + 1];
        for (int i = 0; i <= count; i++) {
            offsets[i] = u32();
            if (i == 0 ? offsets[0] != 0 : offsets[i] < offsets[i - 1]) {
                throw PqcfReader.corrupt("invalid string offsets");
            }
        }
        long total = offsets[count];
        need(total);
        byte[] bytes = chunk.asSlice(pos, total).toArray(ValueLayout.JAVA_BYTE);
        pos += total;
        CharsetDecoder utf8 = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT);
        String[] out = new String[count];
        for (int i = 0; i < count; i++) {
            if (skip != null && skip.get(i)) {
                continue;
            }
            out[i] = utf8(bytes, (int) offsets[i], (int) (offsets[i + 1] - offsets[i]), utf8);
        }
        return out;
    }

    private static String utf8(byte[] bytes, int off, int len, CharsetDecoder decoder) {
        boolean ascii = true;
        for (int i = off; i < off + len; i++) {
            if (bytes[i] < 0) {
                ascii = false;
                break;
            }
        }
        if (ascii) {
            return new String(bytes, off, len, StandardCharsets.ISO_8859_1);
        }
        try {
            CharBuffer chars = decoder.reset().decode(ByteBuffer.wrap(bytes, off, len));
            return chars.toString();
        } catch (CharacterCodingException e) {
            throw PqcfReader.corrupt("invalid UTF-8 in STRING data");
        }
    }

    // ---------------------------------------------------------------- DICT

    private ColumnVector dict() {
        long d = u32();
        if (4 * (d + 1) > chunk.byteSize()) {
            throw PqcfReader.corrupt("dictionary size exceeds the chunk");
        }
        String[] dictionary = strings((int) d, null);
        need(4L * n);
        int[] codes = new int[n];
        for (int i = 0; i < n; i++) {
            long code = u32();
            if (nulls.get(i)) {
                continue;
            }
            if (code >= d) {
                throw PqcfReader.corrupt("dictionary code out of range");
            }
            codes[i] = (int) code;
        }
        return ColumnVector.ofDictionary(dictionary, codes, nulls);
    }

    // ---------------------------------------------------------------- RLE

    private ColumnVector rle() {
        long runs = u32();
        need(12 * runs);
        long[] slots = new long[n];
        long row = 0;
        for (long r = 0; r < runs; r++) {
            long value = i64();
            long length = u32();
            if (length < 1 || row + length > n) {
                throw PqcfReader.corrupt("invalid RLE run length");
            }
            int from = (int) row;
            int to = (int) (row + length);
            int firstValid = nulls.nextClearBit(from);
            if (firstValid < to) {
                checkLong(value);
            }
            Arrays.fill(slots, from, to, value);
            row += length;
        }
        if (row != n) {
            throw PqcfReader.corrupt("RLE runs do not cover the row group");
        }
        for (int i = nulls.nextSetBit(0); i >= 0; i = nulls.nextSetBit(i + 1)) {
            slots[i] = 0;
        }
        return switch (type.kind()) {
            case BOOLEAN -> {
                BitSet values = new BitSet(n);
                for (int i = 0; i < n; i++) {
                    if (slots[i] != 0) {
                        values.set(i);
                    }
                }
                yield ColumnVector.ofBooleans(values, nulls, n);
            }
            case DATE -> {
                int[] values = new int[n];
                for (int i = 0; i < n; i++) {
                    values[i] = (int) slots[i];
                }
                yield ColumnVector.ofInts(type, values, nulls);
            }
            default -> ColumnVector.ofLongs(type, slots, nulls);
        };
    }
}
