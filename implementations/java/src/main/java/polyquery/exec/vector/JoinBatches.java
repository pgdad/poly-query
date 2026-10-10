package polyquery.exec.vector;

import java.util.Arrays;
import java.util.List;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.exec.ExecContext;
import polyquery.plan.BoundExpr;
import polyquery.storage.ColumnSchema;
import polyquery.types.DataType;
import polyquery.types.Decimals;
import polyquery.types.TypeKind;

/** Vectorized hash join: a columnar build table and a batch probe. */
final class JoinBatches {
    private JoinBatches() {
    }

    /**
     * DECIMAL join keys of different scales on the two sides are compared at the larger scale:
     * returns, per key, the power of ten the {@code mine} side's values are multiplied by (1 if none).
     */
    static long[] scaleFactors(List<BoundExpr> mine, List<BoundExpr> other) {
        long[] out = new long[mine.size()];
        for (int j = 0; j < out.length; j++) {
            DataType a = mine.get(j).type();
            DataType b = other.get(j).type();
            out[j] = a.kind() == TypeKind.DECIMAL && b.kind() == TypeKind.DECIMAL && a.scale() < b.scale()
                    ? Decimals.pow10(b.scale() - a.scale()) : 1;
        }
        return out;
    }

    /**
     * Rescales DECIMAL key vectors (see {@link #scaleFactors}); a value whose rescaled form does
     * not fit a long cannot equal any key of the other side and becomes NULL (never matches).
     */
    static Vec[] normalize(Vec[] keys, long[] factors, Vec[] scratch, Batch b) {
        Vec[] out = keys;
        for (int j = 0; j < factors.length; j++) {
            if (factors[j] == 1) {
                continue;
            }
            if (out == keys) {
                out = keys.clone();
            }
            if (scratch[j] == null) {
                scratch[j] = new Vec(keys[j].type, b.size);
            }
            Vec in = keys[j];
            Vec v = scratch[j];
            v.ensure(b.size);
            boolean[] m = v.nullMask(b.size);
            long f = factors[j];
            for (int k = 0; k < b.count; k++) {
                int i = b.pos(k);
                if (in.isNull(i)) {
                    m[i] = true;
                    continue;
                }
                long x = in.longs[i];
                long hi = Math.multiplyHigh(x, f);
                long lo = x * f;
                boolean fits = hi == 0 && lo >= 0 || hi == -1 && lo < 0;
                m[i] = !fits;
                v.longs[i] = lo;
            }
            out[j] = v;
        }
        return out;
    }

    /**
     * The materialized build input: its rows in a column store (all slots of the input that are
     * filled), a key table and, per distinct key, the chain of build rows in input order. Rows
     * with a NULL key component are not stored (they never match). Immutable once built, so
     * parallel probes may share it.
     */
    static final class JoinTable {
        private final List<ColumnSchema> schema;
        private final ExecContext ctx;
        private Vec[] store;
        private int rows;
        private int capacity;
        private GroupKeys keys;
        private int[] first;
        private int[] last;
        private int[] next;
        private long reserved;

        JoinTable(List<ColumnSchema> schema, ExecContext ctx) {
            this.schema = schema;
            this.ctx = ctx;
        }

        Vec column(int slot) {
            return store[slot];
        }

        GroupKeys keys() {
            return keys;
        }

        int first(int key) {
            return first[key];
        }

        int next(int row) {
            return next[row];
        }

        /** Consumes the build input completely (raising its deferred error, if any, at the end). */
        void build(BatchOperator input, BatchExprs keyExprs, long[] factors, DataType[] keyTypes) {
            keys = new GroupKeys(keyTypes);
            rows = 0;
            capacity = 64;
            store = new Vec[schema.size()];
            for (int c = 0; c < store.length; c++) {
                store[c] = new Vec(schema.get(c).type(), capacity);
                store[c].nullMask(capacity);
            }
            first = new int[16];
            Arrays.fill(first, -1);
            last = new int[16];
            next = new int[capacity];
            Vec[] scratch = new Vec[factors.length];
            int[] gids = new int[0];
            int[] keep = new int[0];
            input.open();
            try {
                Batch b;
                while ((b = input.next()) != null) {
                    ctx.checkNow();
                    if (b.count > 0) {
                        Vec[] kv = normalize(keyExprs.eval(b), factors, scratch, b);
                        if (gids.length < b.size) {
                            gids = new int[Math.max(b.size, 16)];
                            keep = new int[gids.length];
                        }
                        keys.groupIds(kv, b.sel, b.count, b.size, gids);
                        int m = 0;
                        for (int k = 0; k < b.count; k++) {
                            int i = b.pos(k);
                            if (!keys.hasNull(gids[i])) {
                                keep[m++] = i;
                            }
                        }
                        append(b, keep, m, gids);
                    }
                    if (b.error != null) {
                        throw b.error;
                    }
                }
            } finally {
                input.close();
            }
        }

        private void append(Batch b, int[] keep, int m, int[] gids) {
            int need = rows + m;
            if (need > capacity) {
                capacity = Math.max(need, capacity * 2);
                next = Arrays.copyOf(next, capacity);
                for (Vec v : store) {
                    v.grow(capacity);
                }
            }
            for (int c = 0; c < store.length; c++) {
                Vec dst = store[c];
                Vec src = b.cols[c];
                for (int k = 0; k < m; k++) {
                    if (src == null) {
                        dst.nulls[rows + k] = true; // a slot nobody reads
                    } else {
                        dst.copyFrom(src, keep[k], rows + k);
                    }
                }
            }
            int groups = keys.groupCount();
            if (first.length < groups) {
                int cap = Math.max(groups, first.length * 2);
                int old = first.length;
                first = Arrays.copyOf(first, cap);
                last = Arrays.copyOf(last, cap);
                Arrays.fill(first, old, cap, -1);
            }
            for (int k = 0; k < m; k++) {
                int r = rows + k;
                int g = gids[keep[k]];
                next[r] = -1;
                if (first[g] < 0) {
                    first[g] = r;
                } else {
                    next[last[g]] = r;
                }
                last[g] = r;
            }
            rows = need;
            long bytes = (long) m * (16 + 12L * schema.size());
            ctx.reserve(bytes);
            reserved += bytes;
        }

        void release() {
            ctx.release(reserved);
            reserved = 0;
            store = null;
            keys = null;
        }
    }

    /**
     * Probes a join table with batches of the probe input. Output rows (probe row, matching build
     * row) appear in probe order and, per probe row, in build input order; for a LEFT join an
     * unmatched probe row is padded with NULLs right after its candidates — exactly the row
     * engine's order, so row-level effects (errors, join row limit) happen at the same rows.
     */
    static final class Probe implements BatchOperator {
        private final BatchOperator input;
        private final JoinTable table;
        private final boolean ownsTable;
        private final BatchOperator buildInput;
        private final BatchExprs buildKeys;
        private final long[] buildFactors;
        private final DataType[] keyTypes;
        private final BatchExprs probeKeys;
        private final long[] probeFactors;
        private final BatchExprs residual;
        private final boolean leftOuter;
        private final boolean buildIsLeft;
        private final int probeWidth;
        private final int buildWidth;
        private final ExecContext ctx;
        private final JoinCounter counter;
        private final int capacity;
        private final Batch out;
        private final Vec[] outVecs;
        private final List<ColumnSchema> outSchema;
        private GroupKeys keys;
        private Vec[] keyScratch;
        private Batch cur;
        private int k;
        private int chain;
        private int[] gids = new int[0];
        private final int[] entryPos;
        private final int[] entryRow;
        private final int[] sel;
        private final int[] nonPad;
        private int lastRowPos;
        private boolean lastRowMatched;
        private boolean done;

        /**
         * @param table       a prebuilt shared table, or null to build one from {@code buildInput} at open
         * @param buildIsLeft the build input supplies the left columns (INNER joins only)
         */
        Probe(BatchOperator input, JoinTable table, BatchOperator buildInput, BatchExprs buildKeys, long[] buildFactors,
              DataType[] keyTypes, BatchExprs probeKeys, long[] probeFactors, BatchExprs residual, boolean leftOuter,
              boolean buildIsLeft, List<ColumnSchema> outSchema, int probeWidth, ExecContext ctx, JoinCounter counter,
              int capacity) {
            this.input = input;
            this.ownsTable = table == null;
            this.table = table != null ? table : new JoinTable(
                    buildIsLeft ? outSchema.subList(0, outSchema.size() - probeWidth)
                            : outSchema.subList(probeWidth, outSchema.size()), ctx);
            this.buildInput = buildInput;
            this.buildKeys = buildKeys;
            this.buildFactors = buildFactors;
            this.keyTypes = keyTypes;
            this.probeKeys = probeKeys;
            this.probeFactors = probeFactors;
            this.residual = residual;
            this.leftOuter = leftOuter;
            this.buildIsLeft = buildIsLeft;
            this.probeWidth = probeWidth;
            this.buildWidth = outSchema.size() - probeWidth;
            this.ctx = ctx;
            this.counter = counter;
            this.capacity = capacity;
            this.outSchema = outSchema;
            this.out = new Batch(outSchema.size());
            this.outVecs = new Vec[outSchema.size()];
            this.entryPos = new int[capacity];
            this.entryRow = new int[capacity];
            this.sel = new int[capacity];
            this.nonPad = new int[capacity];
            this.keyScratch = new Vec[probeFactors.length];
        }

        private int probeSlot(int c) {
            return buildIsLeft ? buildWidth + c : c;
        }

        private int buildSlot(int c) {
            return buildIsLeft ? c : probeWidth + c;
        }

        @Override
        public void open() {
            if (ownsTable) {
                counter.reset();
                table.build(buildInput, buildKeys, buildFactors, keyTypes);
            }
            keys = table.keys().prober();
            input.open();
            cur = null;
            done = false;
            lastRowPos = -1;
        }

        private void startBatch(Batch b) {
            cur = b;
            k = 0;
            chain = -2;
            lastRowPos = -1;
            if (b.count > 0) {
                Vec[] kv = normalize(probeKeys.eval(b), probeFactors, keyScratch, b);
                if (gids.length < b.size) {
                    gids = new int[Math.max(b.size, 16)];
                }
                keys.lookup(kv, b.sel, b.count, b.size, gids, false);
            }
        }

        @Override
        public Batch next() {
            while (!done) {
                int m = 0;
                RuntimeException error = null;
                while (m < capacity) {
                    if (cur == null) {
                        Batch b = input.next();
                        if (b == null) {
                            done = true;
                            break;
                        }
                        startBatch(b);
                    }
                    if (k >= cur.count) {
                        if (m > 0) {
                            break; // output batches never mix probe batches
                        }
                        if (cur.error != null) {
                            error = cur.error;
                            done = true;
                            break;
                        }
                        cur = null;
                        continue;
                    }
                    int i = cur.pos(k);
                    if (chain == -2) {
                        int g = gids[i];
                        chain = g < 0 ? -1 : table.first(g);
                    }
                    if (chain >= 0) {
                        entryPos[m] = i;
                        entryRow[m] = chain;
                        m++;
                        chain = table.next(chain);
                        continue;
                    }
                    if (leftOuter) {
                        entryPos[m] = i;
                        entryRow[m] = -1;
                        m++;
                    }
                    k++;
                    chain = -2;
                }
                Batch result = assemble(m, error);
                if (result != null) {
                    return result;
                }
            }
            return null;
        }

        private Vec outVec(int slot) {
            if (outVecs[slot] == null) {
                outVecs[slot] = new Vec(outSchema.get(slot).type(), capacity);
            }
            return outVecs[slot];
        }

        /** Gathers the entries into the output batch, applies the residual and LEFT JOIN padding. */
        private Batch assemble(int m, RuntimeException error) {
            if (m == 0) {
                if (error == null) {
                    return null;
                }
                out.reset(0);
                out.error = error;
                return out;
            }
            for (int c = 0; c < probeWidth; c++) {
                Vec src = cur.cols[c];
                int slot = probeSlot(c);
                if (src == null) {
                    out.cols[slot] = null;
                    continue;
                }
                Vec dst = outVec(slot);
                dst.nullMask(capacity);
                for (int e = 0; e < m; e++) {
                    dst.copyFrom(src, entryPos[e], e);
                }
                out.cols[slot] = dst;
            }
            for (int c = 0; c < buildWidth; c++) {
                Vec src = table.column(c);
                int slot = buildSlot(c);
                Vec dst = outVec(slot);
                boolean[] nm = dst.nullMask(capacity);
                for (int e = 0; e < m; e++) {
                    int r = entryRow[e];
                    if (r < 0) {
                        nm[e] = true;
                        if (dst.kind == Vec.Kind.OBJECT) {
                            dst.objects[e] = null;
                        }
                    } else {
                        dst.copyFrom(src, r, e);
                    }
                }
                out.cols[slot] = dst;
            }
            out.reset(m);
            int limit = m; // entries at or after this index are dropped (residual error)
            Vec pass = null;
            if (residual != null) {
                int np = 0;
                for (int e = 0; e < m; e++) {
                    if (entryRow[e] >= 0) {
                        nonPad[np++] = e;
                    }
                }
                out.sel = nonPad;
                out.count = np;
                if (np > 0) {
                    pass = residual.eval(out)[0];
                    if (out.count < np) {
                        limit = nonPad[out.count];
                        error = out.error;
                        done = true;
                    }
                }
                out.sel = null;
            }
            int count = 0;
            for (int e = 0; e < limit; e++) {
                int p = entryPos[e];
                if (p != lastRowPos) {
                    lastRowPos = p;
                    lastRowMatched = false;
                }
                boolean keepRow;
                if (entryRow[e] >= 0) {
                    keepRow = pass == null || !pass.isNull(e) && pass.longs[e] == 1;
                    lastRowMatched |= keepRow;
                } else {
                    keepRow = !lastRowMatched;
                }
                if (keepRow) {
                    if (!counter.add()) {
                        error = new PolyQueryException(ErrorCode.RESOURCE_LIMIT,
                                "join produced more than " + ctx.maxJoinRows() + " rows");
                        done = true;
                        break;
                    }
                    sel[count++] = e;
                }
            }
            out.size = m;
            out.sel = count == m ? null : sel;
            out.count = count;
            out.error = error;
            return count > 0 || error != null ? out : null;
        }

        @Override
        public void close() {
            input.close();
            if (ownsTable) {
                table.release();
            }
            cur = null;
        }
    }

    /** Counts a join's output rows against {@code --max-join-rows} (shared by parallel probes). */
    static final class JoinCounter {
        private final long max;
        private final java.util.concurrent.atomic.AtomicLong produced = new java.util.concurrent.atomic.AtomicLong();

        JoinCounter(long max) {
            this.max = max;
        }

        /** Counts one row; false if the limit is exceeded. */
        boolean add() {
            return produced.incrementAndGet() <= max;
        }

        void reset() {
            produced.set(0);
        }
    }
}
