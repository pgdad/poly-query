package polyquery.storage.pqcf;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** Growable little-endian byte buffer used to build column chunks. */
final class ByteSink {
    private byte[] buf;
    private int size;

    ByteSink(int capacity) {
        buf = new byte[Math.max(16, capacity)];
    }

    private void ensure(int extra) {
        long need = (long) size + extra;
        if (need > buf.length) {
            if (need > Integer.MAX_VALUE - 16) {
                throw new IllegalStateException("column chunk too large");
            }
            buf = Arrays.copyOf(buf, (int) Math.max(need, Math.min(Integer.MAX_VALUE - 16L, buf.length * 2L)));
        }
    }

    void putByte(int v) {
        ensure(1);
        buf[size++] = (byte) v;
    }

    void putInt(int v) {
        ensure(4);
        buf[size++] = (byte) v;
        buf[size++] = (byte) (v >>> 8);
        buf[size++] = (byte) (v >>> 16);
        buf[size++] = (byte) (v >>> 24);
    }

    void putLong(long v) {
        ensure(8);
        for (int i = 0; i < 8; i++) {
            buf[size++] = (byte) (v >>> (8 * i));
        }
    }

    void putBytes(byte[] b) {
        ensure(b.length);
        System.arraycopy(b, 0, buf, size, b.length);
        size += b.length;
    }

    /** Appends an LSB-first bitmap of {@code n} bits. */
    void putBitmap(java.util.function.IntPredicate bit, int n) {
        int bytes = (n + 7) / 8;
        ensure(bytes);
        for (int i = 0; i < n; i++) {
            if (bit.test(i)) {
                buf[size + (i >>> 3)] |= (byte) (1 << (i & 7));
            }
        }
        size += bytes;
    }

    /** UTF-8 bytes of each string (null → empty). */
    static byte[][] utf8(String[] values) {
        byte[][] out = new byte[values.length][];
        for (int i = 0; i < values.length; i++) {
            out[i] = values[i] == null ? new byte[0] : values[i].getBytes(StandardCharsets.UTF_8);
        }
        return out;
    }

    int size() {
        return size;
    }

    byte[] toByteArray() {
        return Arrays.copyOf(buf, size);
    }
}
