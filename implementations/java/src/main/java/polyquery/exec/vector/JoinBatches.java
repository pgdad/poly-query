package polyquery.exec.vector;

import java.math.BigInteger;
import java.util.Arrays;
import java.util.List;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.exec.ExecContext;
import polyquery.plan.BoundExpr;
import polyquery.storage.ColumnSchema;
import polyquery.types.DataType;
import polyquery.types.Decimals;

/** Vectorized hash join: a columnar build table and a batch probe. */
final class JoinBatches {
    private JoinBatches() {
    }

    /**
     * Exact numeric join keys (INT64 / DECIMAL) of different scales on the two sides are compared
     * at the larger scale: returns, per key, the number of decimal digits the {@code mine} side's
     * values are shifted left by (0 if none).
     */
    static int[] scaleFactors(List<BoundExpr> mine, List<BoundExpr> other) {
        int[] out = new int[mine.size()];
        for (int j = 0; j < out.length; j++) {
            DataType a = mine.get(j).type();
            DataType b = other.get(j).type();
            out[j] = a.isExactNumeric() && b.isExactNumeric() ? Math.max(0, b.exactScale() - a.exactScale()) : 0;
        }
        return out;
    }

    /**
     * Rescales exact numeric key vectors (see {@link #scaleFactors}). For LONG vectors, a value
     * whose rescaled form does not fit a long cannot equal any key of the other side and becomes
     * NULL (never matches); wide DECIMAL keys (BigInteger) are rescaled exactly.
     */
    static Vec[] normalize(Vec[] keys, int[] shifts, Vec[] scratch, Batch b) {
        Vec[] out = keys;
        for (int j = 0; j < shifts.length; j++) {
            if (shifts[j] == 0) {
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
            if (in.kind == Vec.Kind.OBJECT) {
                BigInteger f = Decimals.bigPow10(shifts[j]);
                for (int k = 0; k < b.count; k++) {
                    int i = b.pos(k);
                    m[i] = in.isNull(i);
                    v.objects[i] = m[i] ? null : ((BigInteger) in.objects[i]).multiply(f);
                }
                out[j] = v;
                continue;
            }
            long f = Decimals.pow10(shifts[j]);
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
        private ColumnStore store;
        private GroupKeys keys;
        /** Single 64-bit key: index partitions by key hash (one unless built in parallel). */
        private LongIndex[] longIndex;
        private int partitionBits;
        private long[] rowKeys;
        private int[] first;
        private int[] last;
        private int[] next;
        private long reserved;

        JoinTable(List<ColumnSchema> schema, ExecContext ctx) {
            this.schema = schema;
            this.ctx = ctx;
        }

        int rows() {
            return store.rows();
        }

        /** Stored values of a build slot, or null if no row was stored or no consumer reads it. */
        Vec column(int slot) {
            return store.column(slot);
        }

        /** Per-probe lookup state (a private view of the key table), or null if none is needed. */
        GroupKeys prober() {
            return keys == null ? null : keys.prober();
        }

        /**
         * For the active rows of a probe batch with key vectors {@code kv}: the first build row
         * with an equal key (NULL keys never match), or -1, written to {@code heads} by position.
         */
        void heads(Vec[] kv, int[] sel, int n, int size, int[] heads, GroupKeys prober) {
            if (longIndex != null) {
                Vec v = kv[0];
                long[] x = v.longs;
                if (partitionBits == 0) {
                    LongIndex index = longIndex[0];
                    for (int kk = 0; kk < n; kk++) {
                        int i = sel == null ? kk : sel[kk];
                        heads[i] = v.isNull(i) ? -1 : index.head(x[i]);
                    }
                } else {
                    for (int kk = 0; kk < n; kk++) {
                        int i = sel == null ? kk : sel[kk];
                        heads[i] = v.isNull(i) ? -1 : longIndex[partition(x[i])].head(x[i]);
                    }
                }
                return;
            }
            prober.lookup(kv, sel, n, size, heads, false);
            for (int kk = 0; kk < n; kk++) {
                int i = sel == null ? kk : sel[kk];
                int g = heads[i];
                heads[i] = g < 0 ? -1 : first[g];
            }
        }

        int next(int row) {
            return next[row];
        }

        /** Index partition of a key (independent bits of a different hash than the index slots). */
        private int partition(long key) {
            return (int) ((key * 0xC2B2AE3D27D4EB4FL) >>> (64 - partitionBits));
        }

        /**
         * Builds the single-key index over the stored rows: as one table, or — for large inputs
         * with several threads — as hash partitions built in parallel, each inserting its rows in
         * input order (so every chain still lists equal keys in build input order).
         */
        private void indexLongKeys(int threads) {
            int rows = store.rows();
            partitionBits = 0;
            if (threads > 1 && rows >= Integer.getInteger("polyquery.parallelBuildRows", PARALLEL_BUILD_ROWS)) {
                partitionBits = Math.min(6, 32 - Integer.numberOfLeadingZeros(threads - 1) + 1);
            }
            int parts = 1 << partitionBits;
            longIndex = new LongIndex[parts];
            if (parts == 1) {
                LongIndex index = new LongIndex();
                for (int r = 0; r < rows; r++) {
                    index.add(rowKeys[r], r, next);
                }
                longIndex[0] = index;
                return;
            }
            int[] start = new int[parts + 1];
            int[] partOf = new int[rows];
            for (int r = 0; r < rows; r++) {
                partOf[r] = partition(rowKeys[r]);
                start[partOf[r] + 1]++;
            }
            for (int p = 0; p < parts; p++) {
                start[p + 1] += start[p];
            }
            int[] members = new int[rows];
            int[] fill = Arrays.copyOf(start, parts);
            for (int r = 0; r < rows; r++) {
                members[fill[partOf[r]]++] = r; // ascending row order within each partition
            }
            List<Runnable> tasks = new java.util.ArrayList<>();
            for (int p = 0; p < parts; p++) {
                int part = p;
                tasks.add(() -> {
                    LongIndex index = new LongIndex();
                    for (int k = start[part]; k < start[part + 1]; k++) {
                        index.add(rowKeys[members[k]], members[k], next);
                    }
                    longIndex[part] = index;
                });
            }
            Parallel.runAll(tasks, ctx);
        }

        /** Consumes the build input completely (raising its deferred error, if any, at the end). */
        void build(BatchOperator input, BatchExprs keyExprs, int[] factors, DataType[] keyTypes, int expectedRows,
                   int threads) {
            boolean singleLong = keyTypes.length == 1 && Vec.kindOf(keyTypes[0]) == Vec.Kind.LONG;
            keys = singleLong ? null : new GroupKeys(keyTypes, ctx.nativeKernels());
            longIndex = null;
            rowKeys = singleLong ? new long[Math.max(64, expectedRows)] : null;
            store = new ColumnStore(schema, expectedRows);
            first = new int[16];
            Arrays.fill(first, -1);
            last = new int[16];
            next = new int[Math.max(64, expectedRows)];
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
                        if (singleLong) {
                            int m = 0;
                            for (int k = 0; k < b.count; k++) {
                                int i = b.pos(k);
                                if (!kv[0].isNull(i)) {
                                    keep[m++] = i;
                                }
                            }
                            appendLong(b, keep, m, kv[0]);
                        } else {
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
                    }
                    if (b.error != null) {
                        throw b.error;
                    }
                }
            } finally {
                input.close();
            }
            if (singleLong) {
                indexLongKeys(threads);
            }
        }

        private void appendLong(Batch b, int[] keep, int m, Vec key) {
            int start = store.append(b, keep, m);
            if (next.length < store.rows()) {
                next = Arrays.copyOf(next, Math.max(store.rows(), next.length * 2));
            }
            if (rowKeys.length < store.rows()) {
                rowKeys = Arrays.copyOf(rowKeys, Math.max(store.rows(), rowKeys.length * 2));
            }
            for (int k = 0; k < m; k++) {
                rowKeys[start + k] = key.longs[keep[k]];
            }
            long bytes = ColumnStore.estimate(b, keep, m) + 40L * m;
            ctx.reserve(bytes);
            reserved += bytes;
        }

        private void append(Batch b, int[] keep, int m, int[] gids) {
            int start = store.append(b, keep, m);
            if (next.length < store.rows()) {
                next = Arrays.copyOf(next, Math.max(store.rows(), next.length * 2));
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
                int r = start + k;
                int g = gids[keep[k]];
                next[r] = -1;
                if (first[g] < 0) {
                    first[g] = r;
                } else {
                    next[last[g]] = r;
                }
                last[g] = r;
            }
            long bytes = ColumnStore.estimate(b, keep, m) + 32L * m;
            ctx.reserve(bytes);
            reserved += bytes;
        }

        void release() {
            ctx.release(reserved);
            reserved = 0;
            store = null;
            keys = null;
            longIndex = null;
            rowKeys = null;
        }
    }

    /** Default: build sides with at least this many rows get their key index built in parallel. */
    static final int PARALLEL_BUILD_ROWS = 1 << 17;

    /**
     * Open-addressing hash index from a single 64-bit join key to the chain of build rows with
     * that key: the key is stored inline in its slot (linear probing, multiplicative hashing),
     * so a probe usually costs a single cache miss.
     */
    static final class LongIndex {
        private long[] keys = new long[64];
        private int[] heads = new int[64];
        private int[] tails = new int[64];
        private int shift = 64 - 6;
        private int mask = 63;
        private int size;

        LongIndex() {
            Arrays.fill(heads, -1);
        }

        private int slot(long key) {
            return (int) ((key * 0x9E3779B97F4A7C15L) >>> shift);
        }

        /** Appends build row {@code row} to the chain of {@code key} ({@code next} links the chain). */
        void add(long key, int row, int[] next) {
            int s = slot(key);
            while (heads[s] >= 0 && keys[s] != key) {
                s = (s + 1) & mask;
            }
            next[row] = -1;
            if (heads[s] < 0) {
                keys[s] = key;
                heads[s] = row;
                tails[s] = row;
                if (++size * 2 > heads.length) {
                    grow();
                }
            } else {
                next[tails[s]] = row;
                tails[s] = row;
            }
        }

        /** First build row with this key, or -1. */
        int head(long key) {
            int s = slot(key);
            while (true) {
                int h = heads[s];
                if (h < 0 || keys[s] == key) {
                    return h;
                }
                s = (s + 1) & mask;
            }
        }

        private void grow() {
            long[] oldKeys = keys;
            int[] oldHeads = heads;
            int[] oldTails = tails;
            int cap = oldHeads.length * 2;
            keys = new long[cap];
            heads = new int[cap];
            tails = new int[cap];
            Arrays.fill(heads, -1);
            mask = cap - 1;
            shift--;
            for (int i = 0; i < oldHeads.length; i++) {
                if (oldHeads[i] >= 0) {
                    int s = slot(oldKeys[i]);
                    while (heads[s] >= 0) {
                        s = (s + 1) & mask;
                    }
                    keys[s] = oldKeys[i];
                    heads[s] = oldHeads[i];
                    tails[s] = oldTails[i];
                }
            }
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
        private final int[] buildFactors;
        private final DataType[] keyTypes;
        private final int expectedBuildRows;
        private final int threads;
        private final BatchExprs probeKeys;
        private final int[] probeFactors;
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
        Probe(BatchOperator input, JoinTable table, BatchOperator buildInput, BatchExprs buildKeys, int[] buildFactors,
              DataType[] keyTypes, int expectedBuildRows, int threads, BatchExprs probeKeys, int[] probeFactors, BatchExprs residual, boolean leftOuter,
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
            this.expectedBuildRows = expectedBuildRows;
            this.threads = threads;
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
                table.build(buildInput, buildKeys, buildFactors, keyTypes, expectedBuildRows, threads);
            }
            keys = table.prober();
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
                table.heads(kv, b.sel, b.count, b.size, gids, keys);
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
                        chain = gids[i];
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
                ColumnStore.gather(src, entryPos, m, dst, 0);
                out.cols[slot] = dst;
            }
            for (int c = 0; c < buildWidth; c++) {
                Vec src = table.column(c);
                int slot = buildSlot(c);
                if (src == null) {
                    if (table.rows() > 0) {
                        out.cols[slot] = null; // a slot nobody reads
                    } else {
                        // empty build side (only LEFT JOIN pads): its columns are all NULL
                        Vec dst = outVec(slot);
                        java.util.Arrays.fill(dst.nullMask(capacity), 0, m, true);
                        if (dst.kind == Vec.Kind.DICT) {
                            dst.toObjects(capacity);
                        }
                        if (dst.kind == Vec.Kind.OBJECT) {
                            java.util.Arrays.fill(dst.objects, 0, m, null);
                        }
                        out.cols[slot] = dst;
                    }
                    continue;
                }
                Vec dst = outVec(slot);
                boolean[] nm = dst.nullMask(capacity);
                if (leftOuter && src.kind == Vec.Kind.DICT) {
                    if (dst.kind != Vec.Kind.DICT || dst.dict != src.dict) {
                        dst.toDict(src.dict, capacity);
                    }
                    for (int e = 0; e < m; e++) {
                        int r = entryRow[e];
                        nm[e] = r < 0 || src.isNull(r);
                        dst.codes[e] = r < 0 ? 0 : src.codes[r];
                    }
                } else if (leftOuter) {
                    if (dst.kind == Vec.Kind.DICT) {
                        dst.toObjects(capacity);
                    }
                    ColumnStore.gatherOrNull(src, entryRow, m, dst);
                } else {
                    ColumnStore.gather(src, entryRow, m, dst, 0);
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
                    sel[count++] = e;
                }
            }
            // one update of the shared counter per batch (not per row: parallel probes share it)
            int allowed = counter.add(count);
            if (allowed < count) {
                count = allowed;
                error = new PolyQueryException(ErrorCode.RESOURCE_LIMIT,
                        "join produced more than " + ctx.maxJoinRows() + " rows");
                done = true;
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

        /** Counts {@code n} rows; returns how many of them are within the limit. */
        int add(int n) {
            if (n == 0) {
                return 0;
            }
            long after = produced.addAndGet(n);
            return after <= max ? n : (int) Math.max(0, n - (after - max));
        }

        void reset() {
            produced.set(0);
        }
    }
}
