package polyquery.exec.vector;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.exec.Evaluator;
import polyquery.exec.ExecContext;
import polyquery.exec.LikeMatcher;
import polyquery.plan.BoundExpr.ArithOp;
import polyquery.plan.BoundExpr.CompareOp;
import polyquery.types.DataType;
import polyquery.types.Decimals;
import polyquery.types.TypeKind;
import polyquery.types.Values;

/**
 * Batch kernels for scalar expressions. Loops over the active positions are written without
 * per-row allocation; null-free inputs take branch-free paths that the JIT can unroll and
 * auto-vectorize (SIMD), with overflow detected by OR-ing flags instead of branching per row.
 */
final class Kernels {
    private Kernels() {
    }

    static PolyQueryException overflow() {
        return new PolyQueryException(ErrorCode.NUMERIC_OVERFLOW, "numeric overflow");
    }

    static PolyQueryException divisionByZero() {
        return new PolyQueryException(ErrorCode.DIVISION_BY_ZERO, "division by zero");
    }

    /**
     * Sets the null mask of {@code out} at the active positions to {@code a.isNull || b.isNull};
     * returns false (and marks {@code out} null-free) if neither input has nulls.
     */
    static boolean unionNulls(Vec out, Vec a, Vec b, int[] sel, int n, int cap) {
        if (!a.hasNulls && !b.hasNulls) {
            out.hasNulls = false;
            return false;
        }
        boolean[] m = out.nullMask(cap);
        for (int k = 0; k < n; k++) {
            int i = sel == null ? k : sel[k];
            m[i] = a.isNull(i) || b.isNull(i);
        }
        return true;
    }

    /** Copies the null mask of {@code a} to {@code out} at the active positions. */
    static boolean copyNulls(Vec out, Vec a, int[] sel, int n, int cap) {
        if (!a.hasNulls) {
            out.hasNulls = false;
            return false;
        }
        boolean[] m = out.nullMask(cap);
        for (int k = 0; k < n; k++) {
            int i = sel == null ? k : sel[k];
            m[i] = a.nulls[i];
        }
        return true;
    }

    // ---------------------------------------------------------------- leaves

    /** A slot of the input batch (no copy). */
    record ColumnRef(int slot) implements VecExpr {
        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            return b.cols[slot];
        }
    }

    /** A constant broadcast to every position. */
    static final class Constant implements VecExpr {
        private final DataType type;
        final Object value;
        private Vec vec;
        private int filled;

        Constant(DataType type, Object value) {
            this.type = type;
            this.value = value;
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            if (vec == null || filled < b.size) {
                filled = Math.max(b.size, Math.max(filled, 16));
                vec = Vec.constant(type, value, filled);
            }
            return vec;
        }
    }

    /** A correlated outer reference: constant for one evaluation of the enclosing subquery. */
    static final class OuterRef implements VecExpr {
        private final ExecContext ctx;
        private final int frame;
        private final int index;
        private final Vec out;

        OuterRef(ExecContext ctx, int frame, int index, DataType type) {
            this.ctx = ctx;
            this.frame = frame;
            this.index = index;
            this.out = new Vec(type, 16);
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            out.ensure(b.size);
            out.fill(ctx.frame(frame)[index], b.size);
            return out;
        }
    }

    /** The shared operand of IN / BETWEEN / simple CASE / NULLIF, set by the enclosing kernel. */
    static final class Operand implements VecExpr {
        Vec current;

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            return current;
        }
    }

    // ---------------------------------------------------------------- arithmetic

    static final class Negate implements VecExpr {
        private final VecExpr input;
        private final TypeKind kind;
        private final Vec out;

        Negate(VecExpr input, DataType type) {
            this.input = input;
            this.kind = type.kind();
            this.out = new Vec(type, 16);
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = input.eval(b, sel, n);
            out.ensure(b.size);
            boolean nul = copyNulls(out, a, sel, n, b.size);
            if (kind == TypeKind.FLOAT64) {
                for (int k = 0; k < n; k++) {
                    int i = sel == null ? k : sel[k];
                    out.doubles[i] = -a.doubles[i];
                }
                return out;
            }
            boolean checkMin = kind == TypeKind.INT64;
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                long x = a.longs[i];
                if (checkMin && x == Long.MIN_VALUE && !(nul && out.nulls[i])) {
                    throw overflow();
                }
                out.longs[i] = -x;
            }
            return out;
        }
    }

    /** INT64 arithmetic with exact overflow and division-by-zero checks. */
    static final class LongArith implements VecExpr {
        private final ArithOp op;
        private final VecExpr left;
        private final VecExpr right;
        private final Vec out;

        LongArith(ArithOp op, VecExpr left, VecExpr right) {
            this.op = op;
            this.left = left;
            this.right = right;
            this.out = new Vec(DataType.INT64, 16);
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = left.eval(b, sel, n);
            Vec c = right.eval(b, sel, n);
            out.ensure(b.size);
            boolean nul = unionNulls(out, a, c, sel, n, b.size);
            long[] x = a.longs;
            long[] y = c.longs;
            long[] r = out.longs;
            boolean[] m = out.nulls;
            if (!nul && sel == null && (op == ArithOp.ADD || op == ArithOp.SUB)) {
                long ov = 0;
                if (op == ArithOp.ADD) {
                    for (int i = 0; i < n; i++) {
                        long s = x[i] + y[i];
                        ov |= (x[i] ^ s) & (y[i] ^ s);
                        r[i] = s;
                    }
                } else {
                    for (int i = 0; i < n; i++) {
                        long s = x[i] - y[i];
                        ov |= (x[i] ^ y[i]) & (x[i] ^ s);
                        r[i] = s;
                    }
                }
                if (ov < 0) {
                    throw overflow();
                }
                return out;
            }
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (nul && m[i]) {
                    continue;
                }
                long p = x[i];
                long q = y[i];
                r[i] = switch (op) {
                    case ADD -> {
                        long s = p + q;
                        if (((p ^ s) & (q ^ s)) < 0) {
                            throw overflow();
                        }
                        yield s;
                    }
                    case SUB -> {
                        long s = p - q;
                        if (((p ^ q) & (p ^ s)) < 0) {
                            throw overflow();
                        }
                        yield s;
                    }
                    case MUL -> {
                        long hi = Math.multiplyHigh(p, q);
                        long lo = p * q;
                        if ((hi != 0 || lo < 0) && (hi != -1 || lo >= 0)) {
                            throw overflow();
                        }
                        yield lo;
                    }
                    case DIV -> {
                        if (q == 0) {
                            throw divisionByZero();
                        }
                        if (p == Long.MIN_VALUE && q == -1) {
                            throw overflow();
                        }
                        yield p / q;
                    }
                    case MOD -> {
                        if (q == 0) {
                            throw divisionByZero();
                        }
                        yield q == -1 ? 0 : p % q;
                    }
                };
            }
            return out;
        }
    }

    /** DECIMAL +, -, * on unscaled values (exact, 18-digit results). */
    static final class DecimalArith implements VecExpr {
        private final ArithOp op;
        private final VecExpr left;
        private final VecExpr right;
        private final int s1;
        private final int s2;
        private final int rs;
        private final Vec out;

        DecimalArith(ArithOp op, VecExpr left, VecExpr right, int s1, int s2, DataType type) {
            this.op = op;
            this.left = left;
            this.right = right;
            this.s1 = s1;
            this.s2 = s2;
            this.rs = type.scale();
            this.out = new Vec(type, 16);
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = left.eval(b, sel, n);
            Vec c = right.eval(b, sel, n);
            out.ensure(b.size);
            boolean nul = unionNulls(out, a, c, sel, n, b.size);
            long[] x = a.longs;
            long[] y = c.longs;
            long[] r = out.longs;
            boolean[] m = out.nulls;
            if (!nul && s1 == rs && s2 == rs && (op == ArithOp.ADD || op == ArithOp.SUB)) {
                // Same scales: plain long arithmetic; |operands| < 10^18 cannot overflow a long.
                boolean bad = false;
                for (int k = 0; k < n; k++) {
                    int i = sel == null ? k : sel[k];
                    long s = op == ArithOp.ADD ? x[i] + y[i] : x[i] - y[i];
                    bad |= s > Decimals.MAX_UNSCALED || s < -Decimals.MAX_UNSCALED;
                    r[i] = s;
                }
                if (bad) {
                    throw Decimals.overflow();
                }
                return out;
            }
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (nul && m[i]) {
                    continue;
                }
                r[i] = switch (op) {
                    case ADD -> Decimals.add(x[i], s1, y[i], s2, rs);
                    case SUB -> Decimals.subtract(x[i], s1, y[i], s2, rs);
                    case MUL -> Decimals.multiply(x[i], y[i]);
                    default -> throw new IllegalStateException("DECIMAL " + op);
                };
            }
            return out;
        }
    }

    /** FLOAT64 arithmetic; infinite/NaN results are NUMERIC_OVERFLOW. */
    static final class DoubleArith implements VecExpr {
        private final ArithOp op;
        private final VecExpr left;
        private final VecExpr right;
        private final Vec out;

        DoubleArith(ArithOp op, VecExpr left, VecExpr right) {
            this.op = op;
            this.left = left;
            this.right = right;
            this.out = new Vec(DataType.FLOAT64, 16);
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = left.eval(b, sel, n);
            Vec c = right.eval(b, sel, n);
            out.ensure(b.size);
            boolean nul = unionNulls(out, a, c, sel, n, b.size);
            double[] x = a.doubles;
            double[] y = c.doubles;
            double[] r = out.doubles;
            boolean[] m = out.nulls;
            boolean bad = false;
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (nul && m[i]) {
                    continue;
                }
                double v = switch (op) {
                    case ADD -> x[i] + y[i];
                    case SUB -> x[i] - y[i];
                    case MUL -> x[i] * y[i];
                    case DIV -> {
                        if (y[i] == 0.0) {
                            throw divisionByZero();
                        }
                        yield x[i] / y[i];
                    }
                    case MOD -> throw new IllegalStateException("FLOAT64 %");
                };
                bad |= Double.isInfinite(v) || Double.isNaN(v);
                r[i] = v;
            }
            if (bad) {
                throw overflow();
            }
            return out;
        }
    }

    // ---------------------------------------------------------------- comparison

    private static boolean test(CompareOp op, int c) {
        return switch (op) {
            case EQ -> c == 0;
            case NEQ -> c != 0;
            case LT -> c < 0;
            case LE -> c <= 0;
            case GT -> c > 0;
            case GE -> c >= 0;
        };
    }

    /** 1 if {@code x < y} (signed), else 0 — without branches (Hacker's Delight 2-12). */
    static long less(long x, long y) {
        long d = x - y;
        return (d ^ ((x ^ y) & (d ^ x))) >>> 63;
    }

    /** Comparison of LONG-represented values of one scale (INT64, DECIMAL, DATE, TIMESTAMP, BOOLEAN). */
    static final class LongCompare implements VecExpr {
        final CompareOp op;
        final VecExpr left;
        final VecExpr right;
        private final Vec out = new Vec(DataType.BOOLEAN, 16);

        LongCompare(CompareOp op, VecExpr left, VecExpr right) {
            this.op = op;
            this.left = left;
            this.right = right;
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = left.eval(b, sel, n);
            Vec c = right.eval(b, sel, n);
            out.ensure(b.size);
            unionNulls(out, a, c, sel, n, b.size);
            long[] x = a.longs;
            long[] y = c.longs;
            long[] r = out.longs;
            if (sel == null) {
                // Branch-free 0/1 results (bit arithmetic; the JIT turns these loops into SIMD code).
                switch (op) {
                    case EQ -> {
                        for (int i = 0; i < n; i++) {
                            long d = x[i] ^ y[i];
                            r[i] = ((d | -d) >>> 63) ^ 1;
                        }
                    }
                    case NEQ -> {
                        for (int i = 0; i < n; i++) {
                            long d = x[i] ^ y[i];
                            r[i] = (d | -d) >>> 63;
                        }
                    }
                    case LT -> {
                        for (int i = 0; i < n; i++) {
                            r[i] = less(x[i], y[i]);
                        }
                    }
                    case LE -> {
                        for (int i = 0; i < n; i++) {
                            r[i] = less(y[i], x[i]) ^ 1;
                        }
                    }
                    case GT -> {
                        for (int i = 0; i < n; i++) {
                            r[i] = less(y[i], x[i]);
                        }
                    }
                    case GE -> {
                        for (int i = 0; i < n; i++) {
                            r[i] = less(x[i], y[i]) ^ 1;
                        }
                    }
                }
                return out;
            }
            for (int k = 0; k < n; k++) {
                int i = sel[k];
                r[i] = test(op, Long.compare(x[i], y[i])) ? 1 : 0;
            }
            return out;
        }
    }

    /** DECIMAL comparison across different scales. */
    static final class DecimalCompare implements VecExpr {
        private final CompareOp op;
        private final VecExpr left;
        private final VecExpr right;
        private final int s1;
        private final int s2;
        private final Vec out = new Vec(DataType.BOOLEAN, 16);

        DecimalCompare(CompareOp op, VecExpr left, VecExpr right, int s1, int s2) {
            this.op = op;
            this.left = left;
            this.right = right;
            this.s1 = s1;
            this.s2 = s2;
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = left.eval(b, sel, n);
            Vec c = right.eval(b, sel, n);
            out.ensure(b.size);
            boolean nul = unionNulls(out, a, c, sel, n, b.size);
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (!(nul && out.nulls[i])) {
                    out.longs[i] = test(op, Decimals.compare(a.longs[i], s1, c.longs[i], s2)) ? 1 : 0;
                }
            }
            return out;
        }
    }

    static final class DoubleCompare implements VecExpr {
        private final CompareOp op;
        private final VecExpr left;
        private final VecExpr right;
        private final Vec out = new Vec(DataType.BOOLEAN, 16);

        DoubleCompare(CompareOp op, VecExpr left, VecExpr right) {
            this.op = op;
            this.left = left;
            this.right = right;
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = left.eval(b, sel, n);
            Vec c = right.eval(b, sel, n);
            out.ensure(b.size);
            unionNulls(out, a, c, sel, n, b.size);
            double[] x = a.doubles;
            double[] y = c.doubles;
            long[] r = out.longs;
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                r[i] = test(op, Values.compareDoubles(x[i], y[i])) ? 1 : 0;
            }
            return out;
        }
    }

    /**
     * STRING comparison (code point order). When the left input is dictionary-encoded and the
     * right side is a constant, each distinct dictionary entry is compared only once.
     */
    static final class StringCompare implements VecExpr {
        private final CompareOp op;
        private final VecExpr left;
        private final VecExpr right;
        private final String constant;
        private final Vec out = new Vec(DataType.BOOLEAN, 16);
        private String[] cachedDict;
        private byte[] cache;

        /** @param constant the right operand if it is a non-null constant, else null */
        StringCompare(CompareOp op, VecExpr left, VecExpr right, String constant) {
            this.op = op;
            this.left = left;
            this.right = right;
            this.constant = constant;
        }

        private boolean compare(String x, String y) {
            if (op == CompareOp.EQ) {
                return x.equals(y);
            }
            if (op == CompareOp.NEQ) {
                return !x.equals(y);
            }
            return test(op, Values.compareStrings(x, y));
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = left.eval(b, sel, n);
            out.ensure(b.size);
            long[] r = out.longs;
            if (constant != null && a.kind == Vec.Kind.DICT) {
                copyNulls(out, a, sel, n, b.size);
                if (cachedDict != a.dict) {
                    cachedDict = a.dict;
                    cache = new byte[a.dict.length]; // 0 = unknown, 1 = false, 2 = true
                }
                int[] codes = a.codes;
                boolean nul = a.hasNulls;
                for (int k = 0; k < n; k++) {
                    int i = sel == null ? k : sel[k];
                    if (nul && a.nulls[i]) {
                        continue;
                    }
                    int code = codes[i];
                    byte v = cache[code];
                    if (v == 0) {
                        v = compare(a.dict[code], constant) ? (byte) 2 : (byte) 1;
                        cache[code] = v;
                    }
                    r[i] = v - 1;
                }
                return out;
            }
            Vec c = right.eval(b, sel, n);
            boolean nul = unionNulls(out, a, c, sel, n, b.size);
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (!(nul && out.nulls[i])) {
                    r[i] = compare(a.string(i), c.string(i)) ? 1 : 0;
                }
            }
            return out;
        }
    }

    // ---------------------------------------------------------------- logic

    static final class Not implements VecExpr {
        private final VecExpr input;
        private final Vec out = new Vec(DataType.BOOLEAN, 16);

        Not(VecExpr input) {
            this.input = input;
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = input.eval(b, sel, n);
            out.ensure(b.size);
            copyNulls(out, a, sel, n, b.size);
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                out.longs[i] = 1 - a.longs[i];
            }
            return out;
        }
    }

    static final class IsNull implements VecExpr {
        final VecExpr input;
        final boolean negated;
        private final Vec out = new Vec(DataType.BOOLEAN, 16);

        IsNull(VecExpr input, boolean negated) {
            this.input = input;
            this.negated = negated;
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = input.eval(b, sel, n);
            out.ensure(b.size);
            out.hasNulls = false;
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                out.longs[i] = a.isNull(i) != negated ? 1 : 0;
            }
            return out;
        }
    }

    /** Positions of {@code sel[0..n)} where boolean vector {@code v} is not {@code skip} (0 = FALSE, 1 = TRUE). */
    static int positionsNot(Vec v, long skip, int[] sel, int n, int[] out) {
        int m = 0;
        for (int k = 0; k < n; k++) {
            int i = sel == null ? k : sel[k];
            if (v.isNull(i) || v.longs[i] != skip) {
                out[m++] = i;
            }
        }
        return m;
    }

    /**
     * Three-valued AND / OR with the row engine's short-circuit: the right operand is evaluated
     * only on rows where the left one does not already decide the result.
     */
    static final class AndOr implements VecExpr {
        final boolean and;
        final VecExpr left;
        final VecExpr right;
        private final Vec out = new Vec(DataType.BOOLEAN, 16);
        private int[] rest = new int[16];

        AndOr(boolean and, VecExpr left, VecExpr right) {
            this.and = and;
            this.left = left;
            this.right = right;
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = left.eval(b, sel, n);
            long decided = and ? 0 : 1; // FALSE decides AND, TRUE decides OR
            if (rest.length < b.size) {
                rest = new int[b.size];
            }
            int m = positionsNot(a, decided, sel, n, rest);
            out.ensure(b.size);
            if (m == 0) {
                copyNulls(out, a, sel, n, b.size);
                for (int k = 0; k < n; k++) {
                    int i = sel == null ? k : sel[k];
                    out.longs[i] = decided;
                }
                return out;
            }
            Vec c = right.eval(b, rest, m);
            boolean[] nm = out.nullMask(b.size);
            boolean anyNull = false;
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                boolean an = a.isNull(i);
                if (!an && a.longs[i] == decided) {
                    nm[i] = false;
                    out.longs[i] = decided;
                    continue;
                }
                boolean cn = c.isNull(i);
                if (!cn && c.longs[i] == decided) {
                    nm[i] = false;
                    out.longs[i] = decided;
                } else if (an || cn) {
                    nm[i] = true;
                    anyNull = true;
                } else {
                    nm[i] = false;
                    out.longs[i] = 1 - decided;
                }
            }
            out.hasNulls = anyNull;
            return out;
        }
    }

    /**
     * {@code operand [NOT] IN (constants)}: membership in a hash set of the constants (all of
     * the operand's type); a NULL constant makes non-members NULL.
     */
    static final class InSet implements VecExpr {
        private final VecExpr operand;
        private final boolean negated;
        private final boolean hasNull;
        private final Set<Object> values;
        private final Vec out = new Vec(DataType.BOOLEAN, 16);
        private String[] cachedDict;
        private byte[] cache;

        /** @param values non-null constants in the operand's representation (Long, Double or String) */
        InSet(VecExpr operand, Set<Object> values, boolean hasNull, boolean negated) {
            this.operand = operand;
            this.values = new HashSet<>(values);
            this.hasNull = hasNull;
            this.negated = negated;
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = operand.eval(b, sel, n);
            out.ensure(b.size);
            boolean[] nm = out.nullMask(b.size);
            boolean dict = a.kind == Vec.Kind.DICT;
            if (dict && cachedDict != a.dict) {
                cachedDict = a.dict;
                cache = new byte[a.dict.length];
            }
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (a.isNull(i)) {
                    nm[i] = true;
                    continue;
                }
                boolean member;
                if (dict) {
                    int code = a.codes[i];
                    if (cache[code] == 0) {
                        cache[code] = values.contains(a.dict[code]) ? (byte) 2 : (byte) 1;
                    }
                    member = cache[code] == 2;
                } else {
                    member = values.contains(switch (a.kind) {
                        case LONG -> a.longs[i];
                        case DOUBLE -> a.doubles[i] == 0.0 ? 0.0 : a.doubles[i];
                        default -> a.objects[i];
                    });
                }
                if (member) {
                    nm[i] = false;
                    out.longs[i] = negated ? 0 : 1;
                } else if (hasNull) {
                    nm[i] = true;
                } else {
                    nm[i] = false;
                    out.longs[i] = negated ? 1 : 0;
                }
            }
            return out;
        }
    }

    /** {@code operand [NOT] IN (e1, e2, …)} with non-constant items: e1, e2, … until one is TRUE. */
    static final class InList implements VecExpr {
        private final VecExpr operand;
        private final Operand holder;
        private final VecExpr[] comparisons;
        private final boolean negated;
        private final Vec out = new Vec(DataType.BOOLEAN, 16);
        private int[] active = new int[16];
        private int[] next = new int[16];
        private boolean[] sawNull = new boolean[16];

        InList(VecExpr operand, Operand holder, VecExpr[] comparisons, boolean negated) {
            this.operand = operand;
            this.holder = holder;
            this.comparisons = comparisons;
            this.negated = negated;
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            holder.current = operand.eval(b, sel, n);
            if (active.length < b.size) {
                active = new int[b.size];
                next = new int[b.size];
                sawNull = new boolean[b.size];
            }
            out.ensure(b.size);
            boolean[] nm = out.nullMask(b.size);
            int m = 0;
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                active[m++] = i;
                sawNull[i] = false;
            }
            for (VecExpr cmp : comparisons) {
                if (m == 0) {
                    break;
                }
                Vec r = cmp.eval(b, active, m);
                int left = 0;
                for (int k = 0; k < m; k++) {
                    int i = active[k];
                    if (r.isNull(i)) {
                        sawNull[i] = true;
                        next[left++] = i;
                    } else if (r.longs[i] == 1) {
                        nm[i] = false;
                        out.longs[i] = negated ? 0 : 1;
                    } else {
                        next[left++] = i;
                    }
                }
                int[] t = active;
                active = next;
                next = t;
                m = left;
            }
            for (int k = 0; k < m; k++) {
                int i = active[k];
                if (sawNull[i]) {
                    nm[i] = true;
                } else {
                    nm[i] = false;
                    out.longs[i] = negated ? 1 : 0;
                }
            }
            return out;
        }
    }

    /** {@code operand [NOT] BETWEEN low AND high}: lower AND upper over the shared operand. */
    static final class Between implements VecExpr {
        final VecExpr operand;
        final Operand holder;
        final VecExpr bounds;
        final boolean negated;
        private final Vec out = new Vec(DataType.BOOLEAN, 16);

        /** @param bounds {@code lower AND upper}, reading the operand through {@code holder} */
        Between(VecExpr operand, Operand holder, VecExpr bounds, boolean negated) {
            this.operand = operand;
            this.holder = holder;
            this.bounds = bounds;
            this.negated = negated;
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            holder.current = operand.eval(b, sel, n);
            Vec r = bounds.eval(b, sel, n);
            if (!negated) {
                return r;
            }
            out.ensure(b.size);
            copyNulls(out, r, sel, n, b.size);
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                out.longs[i] = 1 - r.longs[i];
            }
            return out;
        }
    }

    /** {@code s [NOT] LIKE 'constant pattern'}; per dictionary entry once for dictionary input. */
    static final class Like implements VecExpr {
        private final VecExpr input;
        private final LikeMatcher matcher;
        private final boolean negated;
        private final Vec out = new Vec(DataType.BOOLEAN, 16);
        private String[] cachedDict;
        private byte[] cache;

        Like(VecExpr input, String pattern, boolean negated) {
            this.input = input;
            this.matcher = new LikeMatcher(pattern);
            this.negated = negated;
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = input.eval(b, sel, n);
            out.ensure(b.size);
            copyNulls(out, a, sel, n, b.size);
            boolean dict = a.kind == Vec.Kind.DICT;
            if (dict && cachedDict != a.dict) {
                cachedDict = a.dict;
                cache = new byte[a.dict.length];
            }
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (a.isNull(i)) {
                    continue;
                }
                boolean match;
                if (dict) {
                    int code = a.codes[i];
                    if (cache[code] == 0) {
                        cache[code] = matcher.matches(a.dict[code]) ? (byte) 2 : (byte) 1;
                    }
                    match = cache[code] == 2;
                } else {
                    match = matcher.matches((String) a.objects[i]);
                }
                out.longs[i] = match != negated ? 1 : 0;
            }
            return out;
        }
    }

    // ---------------------------------------------------------------- conditional

    /**
     * CASE: each WHEN condition is evaluated on the rows not yet decided, each THEN result only
     * on the rows it is selected for, ELSE on the rest — exactly the rows the row engine evaluates.
     */
    static final class Case implements VecExpr {
        private final VecExpr operand;
        private final Operand holder;
        private final VecExpr[] conditions;
        private final VecExpr[] results;
        private final VecExpr otherwise;
        private final Vec out;
        private int[] active = new int[16];
        private int[] next = new int[16];
        private int[] chosen = new int[16];

        /** @param operand null for the searched form; otherwise read by the conditions through {@code holder} */
        Case(VecExpr operand, Operand holder, VecExpr[] conditions, VecExpr[] results, VecExpr otherwise,
             DataType type) {
            this.operand = operand;
            this.holder = holder;
            this.conditions = conditions;
            this.results = results;
            this.otherwise = otherwise;
            this.out = new Vec(type, 16);
        }

        private void copy(Batch b, VecExpr expr, int[] rows, int m) {
            Vec r = expr.eval(b, rows, m);
            for (int k = 0; k < m; k++) {
                out.copyFrom(r, rows[k], rows[k]);
            }
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            if (operand != null) {
                holder.current = operand.eval(b, sel, n);
            }
            if (active.length < b.size) {
                active = new int[b.size];
                next = new int[b.size];
                chosen = new int[b.size];
            }
            out.ensure(b.size);
            out.nullMask(b.size);
            int m = 0;
            for (int k = 0; k < n; k++) {
                active[m++] = sel == null ? k : sel[k];
            }
            for (int w = 0; w < conditions.length && m > 0; w++) {
                Vec c = conditions[w].eval(b, active, m);
                int hits = 0;
                int left = 0;
                for (int k = 0; k < m; k++) {
                    int i = active[k];
                    if (!c.isNull(i) && c.longs[i] == 1) {
                        chosen[hits++] = i;
                    } else {
                        next[left++] = i;
                    }
                }
                if (hits > 0) {
                    copy(b, results[w], chosen, hits);
                }
                int[] t = active;
                active = next;
                next = t;
                m = left;
            }
            if (m > 0) {
                copy(b, otherwise, active, m);
            }
            return out;
        }
    }

    /** NULLIF(a, b): NULL where {@code a = b} is TRUE, else a. */
    static final class NullIf implements VecExpr {
        private final VecExpr operand;
        private final Operand holder;
        private final VecExpr equality;
        private final Vec out;

        NullIf(VecExpr operand, Operand holder, VecExpr equality, DataType type) {
            this.operand = operand;
            this.holder = holder;
            this.equality = equality;
            this.out = new Vec(type, 16);
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = operand.eval(b, sel, n);
            holder.current = a;
            Vec eq = equality.eval(b, sel, n);
            out.ensure(b.size);
            boolean[] nm = out.nullMask(b.size);
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (!eq.isNull(i) && eq.longs[i] == 1) {
                    nm[i] = true;
                    if (out.kind == Vec.Kind.OBJECT) {
                        out.objects[i] = null;
                    }
                } else {
                    out.copyFrom(a, i, i);
                }
            }
            return out;
        }
    }

    static final class Concat implements VecExpr {
        private final VecExpr left;
        private final VecExpr right;
        private final Vec out = new Vec(DataType.STRING, 16);

        Concat(VecExpr left, VecExpr right) {
            this.left = left;
            this.right = right;
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = left.eval(b, sel, n);
            Vec c = right.eval(b, sel, n);
            out.ensure(b.size);
            boolean nul = unionNulls(out, a, c, sel, n, b.size);
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                out.objects[i] = nul && out.nulls[i] ? null : a.string(i) + c.string(i);
            }
            return out;
        }
    }

    // ---------------------------------------------------------------- casts

    /** Exact primitive implementations of the common numeric/temporal casts. */
    static final class PrimitiveCast implements VecExpr {
        private final VecExpr input;
        private final DataType from;
        private final DataType to;
        private final Vec out;

        PrimitiveCast(VecExpr input, DataType from, DataType to) {
            this.input = input;
            this.from = from;
            this.to = to;
            this.out = new Vec(to, 16);
        }

        static boolean supports(DataType from, DataType to) {
            TypeKind f = from.kind();
            TypeKind t = to.kind();
            return f == TypeKind.INT64 && (t == TypeKind.DECIMAL || t == TypeKind.FLOAT64)
                    || f == TypeKind.DECIMAL && (t == TypeKind.DECIMAL || t == TypeKind.FLOAT64 || t == TypeKind.INT64)
                    || f == TypeKind.DATE && t == TypeKind.TIMESTAMP
                    || f == TypeKind.TIMESTAMP && t == TypeKind.DATE;
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = input.eval(b, sel, n);
            out.ensure(b.size);
            boolean nul = copyNulls(out, a, sel, n, b.size);
            TypeKind f = from.kind();
            TypeKind t = to.kind();
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                if (nul && out.nulls[i]) {
                    continue;
                }
                long x = a.longs[i];
                if (t == TypeKind.FLOAT64) {
                    out.doubles[i] = f == TypeKind.INT64 ? (double) x : Decimals.toDouble(x, from.scale());
                    continue;
                }
                out.longs[i] = switch (f) {
                    case INT64 -> {
                        long u;
                        try {
                            u = to.scale() == 0 ? x : Math.multiplyExact(x, Decimals.pow10(to.scale()));
                        } catch (ArithmeticException e) {
                            throw overflow();
                        }
                        if (!Decimals.fitsPrecision(u, to.precision())) {
                            throw overflow();
                        }
                        yield u;
                    }
                    case DECIMAL -> {
                        if (t == TypeKind.INT64) {
                            yield Decimals.truncateToInteger(x, from.scale());
                        }
                        long r;
                        try {
                            r = Decimals.rescale(x, from.scale(), to.scale());
                        } catch (PolyQueryException e) {
                            throw overflow();
                        }
                        if (!Decimals.fitsPrecision(r, to.precision())) {
                            throw overflow();
                        }
                        yield r;
                    }
                    case DATE -> x * polyquery.types.DateTimes.MICROS_PER_DAY;
                    default -> Math.floorDiv(x, polyquery.types.DateTimes.MICROS_PER_DAY);
                };
            }
            return out;
        }
    }

    // ---------------------------------------------------------------- row-level fallbacks

    /**
     * Applies row-level code to a vectorized argument: {@code fn} reads the argument value
     * through {@code cell} (a placeholder), e.g. a scalar function or a CAST. Strict: NULL in,
     * NULL out, the function is not called.
     */
    static final class BoxedUnary implements VecExpr {
        private static final Object[] NO_ROW = new Object[0];
        private static final Object UNKNOWN = new Object();
        private final VecExpr input;
        private final Object[] cell;
        private final Evaluator fn;
        private final boolean strict;
        private final boolean deterministic;
        private final Vec out;
        private String[] cachedDict;
        private Object[] cache;

        /** @param deterministic the result depends only on the argument (results may be memoized) */
        BoxedUnary(VecExpr input, Object[] cell, Evaluator fn, boolean strict, boolean deterministic, DataType type) {
            this.input = input;
            this.cell = cell;
            this.fn = fn;
            this.strict = strict;
            this.deterministic = deterministic;
            this.out = new Vec(type, 16);
        }

        private Object apply(Object v) {
            if (v == null && strict) {
                return null;
            }
            cell[0] = v;
            return fn.eval(NO_ROW);
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            Vec a = input.eval(b, sel, n);
            out.ensure(b.size);
            out.nullMask(b.size);
            if (deterministic && a.kind == Vec.Kind.DICT) {
                // once per distinct dictionary entry
                if (cachedDict != a.dict) {
                    cachedDict = a.dict;
                    cache = new Object[a.dict.length];
                    java.util.Arrays.fill(cache, UNKNOWN);
                }
                for (int k = 0; k < n; k++) {
                    int i = sel == null ? k : sel[k];
                    if (a.isNull(i)) {
                        out.set(i, apply(null));
                        continue;
                    }
                    int code = a.codes[i];
                    Object r = cache[code];
                    if (r == UNKNOWN) {
                        r = apply(a.dict[code]);
                        cache[code] = r;
                    }
                    out.set(i, r);
                }
            } else {
                for (int k = 0; k < n; k++) {
                    int i = sel == null ? k : sel[k];
                    out.set(i, apply(a.get(i)));
                }
            }
            cell[0] = null;
            return out;
        }
    }

    /**
     * Evaluates an expression with the row engine, one row at a time: used for constructs
     * without a batch kernel (subqueries, most scalar functions). Only the input slots the
     * expression reads are materialized.
     */
    static final class RowEval implements VecExpr {
        private final Evaluator evaluator;
        private final int[] slots;
        private final Vec out;
        private final Operand operand;
        private final Object[] cell;
        private Object[] row = new Object[0];

        /** @param operand if non-null, its value is passed to {@code evaluator}'s placeholders via {@code cell} */
        RowEval(Evaluator evaluator, int[] slots, DataType type, Operand operand, Object[] cell) {
            this.evaluator = evaluator;
            this.slots = slots;
            this.out = new Vec(type, 16);
            this.operand = operand;
            this.cell = cell;
        }

        @Override
        public Vec eval(Batch b, int[] sel, int n) {
            if (row.length < b.cols.length) {
                row = new Object[b.cols.length];
            }
            out.ensure(b.size);
            out.nullMask(b.size);
            for (int k = 0; k < n; k++) {
                int i = sel == null ? k : sel[k];
                for (int s : slots) {
                    row[s] = b.cols[s] == null ? null : b.cols[s].get(i);
                }
                if (operand != null) {
                    cell[0] = operand.current.get(i);
                }
                out.set(i, evaluator.eval(row));
            }
            Arrays.fill(row, null);
            return out;
        }
    }
}
