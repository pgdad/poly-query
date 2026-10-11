package polyquery.ffi;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Objects;

/**
 * Binding of the native kernel library {@code libpqkernels} (C ABI version 1,
 * {@code native-kernels/include/pq_kernels.h}) through the Foreign Function &amp; Memory API.
 *
 * <p>The library is loaded at most once per process ({@link #load}); an instance of this class is
 * the proof that it was loaded and initialized. The kernels are bound as <em>critical</em>
 * downcalls with heap access: they receive the engine's Java arrays directly (no copying, no
 * off-heap buffers) and run without a thread-state transition, which is appropriate because every
 * kernel is short, non-blocking and never calls back into Java. The method handles are
 * {@code static final}, so the JIT inlines the downcall stubs into the callers.
 *
 * <p>Conventions of the Java signatures: element counts are {@code int}s and every array argument
 * is used from index 0; bitmaps (LSB-first, row i = bit i % 8 of byte i / 8) are {@code long[]}
 * words, which is the same memory layout on a little-endian CPU (the only kind supported); a null
 * validity bitmap means "all rows valid"; {@code uint32_t} index vectors are {@code int[]} (row
 * counts stay below 2^31). Every wrapper checks the array lengths before calling, so a caller bug
 * raises an exception instead of corrupting memory.
 */
public final class NativeKernels {
    /** Comparison operators of the filter/count/compare kernels (PQK_EQ … PQK_BETWEEN). */
    public static final int EQ = 0;
    public static final int NE = 1;
    public static final int LT = 2;
    public static final int LE = 3;
    public static final int GT = 4;
    public static final int GE = 5;
    public static final int BETWEEN = 6;

    /** Status codes. */
    public static final int OK = 0;
    public static final int OVERFLOW = 1;
    public static final int EINVAL = 2;

    /** The ABI version this binding implements. */
    public static final int ABI_VERSION = 1;

    private static NativeKernels loaded;
    private static Path loadedPath;
    /** The library {@link Bindings} binds when it is initialized. */
    private static Path bindingPath;

    private final String variant;
    private final String availableVariants;

    private NativeKernels(String variant, String availableVariants) {
        this.variant = variant;
        this.availableVariants = availableVariants;
    }

    /**
     * Loads and initializes the library at {@code path} (once per process; loading the same path
     * again returns the same instance).
     *
     * @throws NativeLoadException if the library cannot be loaded, lacks a symbol, has another ABI
     *                             version, or the platform is unsupported
     */
    public static synchronized NativeKernels load(Path path) throws NativeLoadException {
        Path p = path.toAbsolutePath().normalize();
        if (loaded != null) {
            if (p.equals(loadedPath)) {
                return loaded;
            }
            throw new NativeLoadException("a native kernel library is already loaded from " + loadedPath);
        }
        if (ByteOrder.nativeOrder() != ByteOrder.LITTLE_ENDIAN) {
            throw new NativeLoadException("native kernels need a little-endian CPU");
        }
        if (!Files.isRegularFile(p)) {
            throw new NativeLoadException("no such file: " + p);
        }
        bindingPath = p;
        try {
            if (Bindings.FAILURE != null) {
                throw new NativeLoadException(Bindings.FAILURE);
            }
        } catch (ExceptionInInitializerError | NoClassDefFoundError e) {
            throw new NativeLoadException("cannot bind native kernels: " + e);
        }
        loaded = new NativeKernels(Bindings.VARIANT, Bindings.AVAILABLE);
        loadedPath = p;
        return loaded;
    }

    /** Name of the variant selected by the library's runtime dispatch (e.g. {@code x86_avx2}). */
    public String variant() {
        return variant;
    }

    /** Comma-separated variants usable on this CPU. */
    public String availableVariants() {
        return availableVariants;
    }

    // ------------------------------------------------------------------ argument helpers

    private static MemorySegment seg(long[] a) {
        return MemorySegment.ofArray(a);
    }

    private static MemorySegment seg(int[] a) {
        return MemorySegment.ofArray(a);
    }

    private static MemorySegment seg(double[] a) {
        return MemorySegment.ofArray(a);
    }

    /** A validity bitmap argument: NULL for "all valid". */
    private static MemorySegment validity(long[] bits, int n) {
        if (bits == null) {
            return MemorySegment.NULL;
        }
        checkBits(bits, n);
        return MemorySegment.ofArray(bits);
    }

    private static void check(int length, int n) {
        if (n < 0 || n > length) {
            throw new IndexOutOfBoundsException("kernel argument of length " + length + " for " + n + " elements");
        }
    }

    private static void checkBits(long[] bits, int nbits) {
        if (nbits < 0 || (long) bits.length * 64 < nbits) {
            throw new IndexOutOfBoundsException("bitmap of " + bits.length + " words for " + nbits + " bits");
        }
    }

    private static int count(long result) {
        if (result < 0) {
            throw new IllegalArgumentException("invalid kernel operator");
        }
        return (int) result;
    }

    private static RuntimeException failure(Throwable t) {
        if (t instanceof RuntimeException r) {
            return r;
        }
        if (t instanceof Error e) {
            throw e;
        }
        return new IllegalStateException(t);
    }

    // ------------------------------------------------------------------ 1. filtering

    /**
     * Writes the ascending indices {@code i < n} where {@code op(data[i], a, b)} holds and row i is
     * valid to {@code outIdx}; returns their number.
     */
    public int filter(long[] data, long[] validity, int n, int op, long a, long b, int[] outIdx) {
        check(data.length, n);
        check(outIdx.length, n);
        try {
            return count((long) Bindings.FILTER_I64.invokeExact(seg(data), validity(validity, n), (long) n, op, a, b,
                    seg(outIdx)));
        } catch (Throwable t) {
            throw failure(t);
        }
    }

    /** The predicate of {@link #filter} as a bitmap of n bits (trailing bits of the last byte zeroed); returns the number of set bits. */
    public int filterBitmap(long[] data, long[] validity, int n, int op, long a, long b, long[] outBits) {
        check(data.length, n);
        checkBits(outBits, n);
        try {
            return count((long) Bindings.FILTER_I64_BITMAP.invokeExact(seg(data), validity(validity, n), (long) n, op,
                    a, b, seg(outBits)));
        } catch (Throwable t) {
            throw failure(t);
        }
    }

    /** Number of valid rows {@code i < n} where {@code op(data[i], a, b)} holds. */
    public int count(long[] data, long[] validity, int n, int op, long a, long b) {
        check(data.length, n);
        try {
            return count((long) Bindings.COUNT_I64.invokeExact(seg(data), validity(validity, n), (long) n, op, a, b));
        } catch (Throwable t) {
            throw failure(t);
        }
    }

    /** Bit i of {@code outBits} = {@code op(a[i], b[i])} (EQ … GE; validity not consulted); returns the number of set bits. */
    public int compare(long[] a, long[] b, int n, int op, long[] outBits) {
        check(a.length, n);
        check(b.length, n);
        checkBits(outBits, n);
        try {
            return count((long) Bindings.COMPARE_I64.invokeExact(seg(a), seg(b), (long) n, op, seg(outBits)));
        } catch (Throwable t) {
            throw failure(t);
        }
    }

    // ------------------------------------------------------------------ 2./3. sums, min/max

    /**
     * Exact sum of the valid values among the first n; stores it in {@code out[0]} and returns
     * {@link #OK}, or returns {@link #OVERFLOW} if the exact sum is outside the INT64 range.
     */
    public int sum(long[] data, long[] validity, int n, long[] out) {
        check(data.length, n);
        check(out.length, 1);
        try {
            return (int) Bindings.SUM_I64.invokeExact(seg(data), validity(validity, n), (long) n, seg(out));
        } catch (Throwable t) {
            throw failure(t);
        }
    }

    /** Sum of the valid doubles (lane-wise reassociated: not bit-identical to a sequential sum). */
    public double sum(double[] data, long[] validity, int n) {
        check(data.length, n);
        try {
            return (double) Bindings.SUM_F64.invokeExact(seg(data), validity(validity, n), (long) n);
        } catch (Throwable t) {
            throw failure(t);
        }
    }

    /** Number of valid values; if positive, {@code out[0]} = minimum and {@code out[1]} = maximum. */
    public int minMax(long[] data, long[] validity, int n, long[] out) {
        check(data.length, n);
        check(out.length, 2);
        MemorySegment o = seg(out);
        try {
            return count((long) Bindings.MINMAX_I64.invokeExact(seg(data), validity(validity, n), (long) n, o,
                    o.asSlice(8)));
        } catch (Throwable t) {
            throw failure(t);
        }
    }

    /** {@link #minMax(long[], long[], int, long[])} for finite doubles. */
    public int minMax(double[] data, long[] validity, int n, double[] out) {
        check(data.length, n);
        check(out.length, 2);
        MemorySegment o = seg(out);
        try {
            return count((long) Bindings.MINMAX_F64.invokeExact(seg(data), validity(validity, n), (long) n, o,
                    o.asSlice(8)));
        } catch (Throwable t) {
            throw failure(t);
        }
    }

    // ------------------------------------------------------------------ 5. bitmaps

    /** {@code out = a & b} over {@code nbytes} bytes ({@code out} may alias an input). */
    public void and(long[] a, long[] b, long[] out, int nbytes) {
        bitmapOp(Bindings.BITMAP_AND, a, b, out, nbytes);
    }

    /** {@code out = a | b} over {@code nbytes} bytes. */
    public void or(long[] a, long[] b, long[] out, int nbytes) {
        bitmapOp(Bindings.BITMAP_OR, a, b, out, nbytes);
    }

    /** {@code out = a & ~b} over {@code nbytes} bytes. */
    public void andNot(long[] a, long[] b, long[] out, int nbytes) {
        bitmapOp(Bindings.BITMAP_ANDNOT, a, b, out, nbytes);
    }

    private static void bitmapOp(MethodHandle op, long[] a, long[] b, long[] out, int nbytes) {
        checkBits(a, nbytes * 8);
        checkBits(b, nbytes * 8);
        checkBits(out, nbytes * 8);
        try {
            op.invokeExact(seg(a), seg(b), seg(out), (long) nbytes);
        } catch (Throwable t) {
            throw failure(t);
        }
    }

    /** Number of set bits among the first {@code nbits}. */
    public int popcount(long[] bits, int nbits) {
        checkBits(bits, nbits);
        try {
            return count((long) Bindings.BITMAP_POPCOUNT.invokeExact(seg(bits), (long) nbits));
        } catch (Throwable t) {
            throw failure(t);
        }
    }

    // ------------------------------------------------------------------ 6. hashing

    /** {@code out[i] = fmix64(data[i] ^ seed)} for {@code i < n} (see {@link #fmix64}). */
    public void hash(long[] data, int n, long seed, long[] out) {
        check(data.length, n);
        check(out.length, n);
        try {
            Bindings.HASH_I64.invokeExact(seg(data), (long) n, seed, seg(out));
        } catch (Throwable t) {
            throw failure(t);
        }
    }

    /** The MurmurHash3 64-bit finalizer, as computed by {@link #hash} (the Java reference). */
    public static long fmix64(long k) {
        k ^= k >>> 33;
        k *= 0xff51afd7ed558ccdL;
        k ^= k >>> 33;
        k *= 0xc4ceb9fe1a85ec53L;
        k ^= k >>> 33;
        return k;
    }

    // ------------------------------------------------------------------ 8. aggregation primitives

    /**
     * For valid rows {@code i < n}: {@code sums[gids[i]] += values[i]} (wrapping) and, if
     * {@code counts} is not null, {@code counts[gids[i]] += 1}. Returns {@link #OK} (all sums
     * exact), {@link #OVERFLOW} (some addition may have wrapped; the outputs were updated with
     * wrapping arithmetic) or {@link #EINVAL} (a group id {@code >= ngroups}; outputs untouched).
     */
    public int groupSum(int[] gids, long[] values, long[] validity, int n, long[] sums, long[] counts, int ngroups) {
        check(gids.length, n);
        check(values.length, n);
        check(sums.length, ngroups);
        if (counts != null) {
            check(counts.length, ngroups);
        }
        MemorySegment countSeg = counts == null ? MemorySegment.NULL : seg(counts);
        try {
            return (int) Bindings.GROUP_SUM_I64.invokeExact(seg(gids), seg(values), validity(validity, n), (long) n,
                    seg(sums), countSeg, (long) ngroups);
        } catch (Throwable t) {
            throw failure(t);
        }
    }

    /**
     * {@code out[j] = data[idx[j]]} for {@code j < m}. The indices must lie within {@code data}
     * (the caller guarantees it; they are not checked one by one).
     */
    public void gather(long[] data, int[] idx, int m, long[] out) {
        check(idx.length, m);
        check(out.length, m);
        Objects.requireNonNull(data);
        try {
            Bindings.GATHER_I64.invokeExact(seg(data), seg(idx), (long) m, seg(out));
        } catch (Throwable t) {
            throw failure(t);
        }
    }

    /** {@link #gather(long[], int[], int, long[])} for doubles (the kernel moves 8-byte values). */
    public void gather(double[] data, int[] idx, int m, double[] out) {
        check(idx.length, m);
        check(out.length, m);
        Objects.requireNonNull(data);
        try {
            Bindings.GATHER_I64.invokeExact(seg(data), seg(idx), (long) m, seg(out));
        } catch (Throwable t) {
            throw failure(t);
        }
    }

    /**
     * The downcall handles. Initialized (once) when {@link #load} first touches this class, from
     * {@link #bindingPath}; on failure the handles are null and {@link #FAILURE} says why.
     */
    @SuppressWarnings("restricted") // native access is enabled by the jar manifest (Enable-Native-Access)
    private static final class Bindings {
        static final String FAILURE;
        static final String VARIANT;
        static final String AVAILABLE;
        static final MethodHandle FILTER_I64;
        static final MethodHandle FILTER_I64_BITMAP;
        static final MethodHandle SUM_I64;
        static final MethodHandle SUM_F64;
        static final MethodHandle MINMAX_I64;
        static final MethodHandle MINMAX_F64;
        static final MethodHandle COUNT_I64;
        static final MethodHandle BITMAP_AND;
        static final MethodHandle BITMAP_OR;
        static final MethodHandle BITMAP_ANDNOT;
        static final MethodHandle BITMAP_POPCOUNT;
        static final MethodHandle HASH_I64;
        static final MethodHandle COMPARE_I64;
        static final MethodHandle GROUP_SUM_I64;
        static final MethodHandle GATHER_I64;

        static {
            String failure = null;
            String variant = null;
            String available = null;
            MethodHandle[] h = new MethodHandle[15];
            try {
                Linker linker = Linker.nativeLinker();
                MemoryLayout sizeT = linker.canonicalLayouts().get("size_t");
                if (!ValueLayout.JAVA_LONG.equals(sizeT)) {
                    throw new IllegalStateException("unsupported size_t layout " + sizeT);
                }
                SymbolLookup lib = SymbolLookup.libraryLookup(bindingPath, Arena.global());
                Binder b = new Binder(linker, lib);
                ValueLayout p = ValueLayout.ADDRESS;
                ValueLayout i32 = ValueLayout.JAVA_INT;
                ValueLayout i64 = ValueLayout.JAVA_LONG;
                ValueLayout f64 = ValueLayout.JAVA_DOUBLE;

                int abi = (int) b.plain("pqk_abi_version", FunctionDescriptor.of(i32)).invokeExact();
                if (abi != ABI_VERSION) {
                    throw new IllegalStateException("library ABI version " + abi + ", expected " + ABI_VERSION);
                }
                int status = (int) b.plain("pqk_init", FunctionDescriptor.of(i32)).invokeExact();
                if (status != OK) {
                    throw new IllegalStateException("pqk_init failed with status " + status);
                }
                MemorySegment v = (MemorySegment) b.plain("pqk_variant", FunctionDescriptor.of(p)).invokeExact();
                MemorySegment a = (MemorySegment) b.plain("pqk_available_variants", FunctionDescriptor.of(p))
                        .invokeExact();
                variant = v.reinterpret(256).getString(0);
                available = a.reinterpret(1024).getString(0);

                h[0] = b.critical("pqk_filter_i64", FunctionDescriptor.of(i64, p, p, i64, i32, i64, i64, p));
                h[1] = b.critical("pqk_filter_i64_bitmap", FunctionDescriptor.of(i64, p, p, i64, i32, i64, i64, p));
                h[2] = b.critical("pqk_sum_i64", FunctionDescriptor.of(i32, p, p, i64, p));
                h[3] = b.critical("pqk_sum_f64", FunctionDescriptor.of(f64, p, p, i64));
                h[4] = b.critical("pqk_minmax_i64", FunctionDescriptor.of(i64, p, p, i64, p, p));
                h[5] = b.critical("pqk_minmax_f64", FunctionDescriptor.of(i64, p, p, i64, p, p));
                h[6] = b.critical("pqk_count_i64", FunctionDescriptor.of(i64, p, p, i64, i32, i64, i64));
                h[7] = b.critical("pqk_bitmap_and", FunctionDescriptor.ofVoid(p, p, p, i64));
                h[8] = b.critical("pqk_bitmap_or", FunctionDescriptor.ofVoid(p, p, p, i64));
                h[9] = b.critical("pqk_bitmap_andnot", FunctionDescriptor.ofVoid(p, p, p, i64));
                h[10] = b.critical("pqk_bitmap_popcount", FunctionDescriptor.of(i64, p, i64));
                h[11] = b.critical("pqk_hash_i64", FunctionDescriptor.ofVoid(p, i64, i64, p));
                h[12] = b.critical("pqk_compare_i64", FunctionDescriptor.of(i64, p, p, i64, i32, p));
                h[13] = b.critical("pqk_group_sum_i64", FunctionDescriptor.of(i32, p, p, p, i64, p, p, i64));
                h[14] = b.critical("pqk_gather_i64", FunctionDescriptor.ofVoid(p, p, i64, p));
            } catch (Throwable t) {
                failure = t.getMessage() == null ? t.toString() : t.getMessage();
                java.util.Arrays.fill(h, null);
            }
            FAILURE = failure;
            VARIANT = variant;
            AVAILABLE = available;
            FILTER_I64 = h[0];
            FILTER_I64_BITMAP = h[1];
            SUM_I64 = h[2];
            SUM_F64 = h[3];
            MINMAX_I64 = h[4];
            MINMAX_F64 = h[5];
            COUNT_I64 = h[6];
            BITMAP_AND = h[7];
            BITMAP_OR = h[8];
            BITMAP_ANDNOT = h[9];
            BITMAP_POPCOUNT = h[10];
            HASH_I64 = h[11];
            COMPARE_I64 = h[12];
            GROUP_SUM_I64 = h[13];
            GATHER_I64 = h[14];
        }

        private Bindings() {
        }
    }

    /** Looks up symbols and creates downcall handles. */
    @SuppressWarnings("restricted")
    private record Binder(Linker linker, SymbolLookup lib) {
        private MemorySegment symbol(String name) {
            return lib.find(name).orElseThrow(() -> new IllegalStateException("missing symbol " + name));
        }

        MethodHandle plain(String name, FunctionDescriptor fd) {
            return linker.downcallHandle(symbol(name), fd);
        }

        /** A kernel: short, non-blocking, no upcalls — may read and write Java arrays in place. */
        MethodHandle critical(String name, FunctionDescriptor fd) {
            return linker.downcallHandle(symbol(name), fd, Linker.Option.critical(true));
        }
    }
}
