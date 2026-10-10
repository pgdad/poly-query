package polyquery.exec.vector;

import java.util.ArrayList;
import java.util.List;
import polyquery.common.PolyQueryException;
import polyquery.exec.ExecContext;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.types.DataType;

/** Hash aggregation and duplicate elimination over batches. */
final class AggregateBatches {
    private AggregateBatches() {
    }

    /** Group keys followed by the aggregate arguments (COUNT(*) has none): the per-row expressions. */
    static List<BoundExpr> inputs(List<BoundExpr> groupKeys, List<AggregateCall> calls) {
        List<BoundExpr> out = new ArrayList<>(groupKeys);
        for (AggregateCall c : calls) {
            if (c.argument() != null) {
                out.add(c.argument());
            }
        }
        return out;
    }

    static DataType[] keyTypes(List<BoundExpr> groupKeys) {
        DataType[] out = new DataType[groupKeys.size()];
        for (int i = 0; i < out.length; i++) {
            out[i] = groupKeys.get(i).type();
        }
        return out;
    }

    /**
     * One aggregation table: group keys plus aggregate states, fed with evaluated input vectors.
     * Also used as the partial table of a parallel worker.
     */
    static final class Table {
        final GroupKeys keys;
        final AggState[] states;
        private final int[] argSlot;
        private final ExecContext ctx;
        private int[] gids = new int[0];
        private long reserved;

        Table(List<BoundExpr> groupKeys, List<AggregateCall> calls, ExecContext ctx) {
            this.keys = new GroupKeys(keyTypes(groupKeys));
            this.states = new AggState[calls.size()];
            this.argSlot = new int[calls.size()];
            this.ctx = ctx;
            int slot = groupKeys.size();
            for (int a = 0; a < states.length; a++) {
                states[a] = AggState.create(calls.get(a));
                argSlot[a] = calls.get(a).argument() == null ? -1 : slot++;
            }
            if (groupKeys.isEmpty()) {
                // an aggregation without GROUP BY has exactly one group, even for empty input
                keys.groupIds(new Vec[0], null, 0, 0, gids);
                growStates();
            }
        }

        boolean mergeable() {
            for (AggState s : states) {
                if (!s.mergeable()) {
                    return false;
                }
            }
            return true;
        }

        int groupCount() {
            return keys.groupCount();
        }

        private void growStates() {
            int g = keys.groupCount();
            for (AggState s : states) {
                s.grow(g);
            }
        }

        /**
         * Adds the active rows of {@code b}; {@code v} = evaluated keys followed by arguments.
         * Returns the group ids of the rows (indexed by position; valid until the next call).
         */
        int[] add(Batch b, Vec[] v) {
            if (b.count == 0) {
                return gids;
            }
            if (gids.length < b.size) {
                gids = new int[Math.max(b.size, 16)];
            }
            int before = keys.groupCount();
            keys.groupIds(v, b.sel, b.count, b.size, gids);
            int created = keys.groupCount() - before;
            if (created > 0) {
                growStates();
                long bytes = created * groupBytes();
                ctx.reserve(bytes);
                reserved += bytes;
            }
            boolean single = keys.keyCount() == 0;
            for (int a = 0; a < states.length; a++) {
                Vec arg = argSlot[a] < 0 ? null : v[argSlot[a]];
                if (single) {
                    states[a].updateSingle(arg, b.sel, b.count, gids);
                } else {
                    states[a].update(arg, b.sel, b.count, gids);
                }
            }
            return gids;
        }

        /** Memory accounted per group, as the row engine estimates it (group entry, accumulators, key row). */
        private long groupBytes() {
            return 64 + 48L * states.length + 16 + 24L * keys.keyCount();
        }

        /** Merges group g of a partial table into this one; returns the group id here. */
        int merge(Table partial, int g) {
            int before = keys.groupCount();
            int to = keys.addFrom(partial.keys, g);
            if (keys.groupCount() > before) {
                growStates();
                long bytes = groupBytes();
                ctx.reserve(bytes);
                reserved += bytes;
            }
            for (int a = 0; a < states.length; a++) {
                states[a].merge(partial.states[a], g, to);
            }
            return to;
        }

        void release() {
            ctx.release(reserved);
            reserved = 0;
        }
    }

    /**
     * Produces the output rows of aggregation tables (group keys then aggregate results) in a
     * given group order, in batches. A failing aggregate result (e.g. SUM overflow) is deferred
     * to the group that raises it, like the row engine's lazy output.
     */
    static final class Emitter {
        private final Table[] tables;
        private final int[] tableOf;
        private final int[] groupOf;
        private final Batch out;
        private final int batchSize;
        private int next;
        private boolean failed;

        /** Groups of one table in id order (i.e. order of first appearance). */
        Emitter(Table table, List<BoundExpr> groupKeys, List<AggregateCall> calls, int batchSize) {
            this(new Table[] {table}, null, null, groupKeys, calls, batchSize);
        }

        /** The groups {@code (tables[tableOf[i]], groupOf[i])} in order of i. */
        Emitter(Table[] tables, int[] tableOf, int[] groupOf, List<BoundExpr> groupKeys, List<AggregateCall> calls,
                int batchSize) {
            this.tables = tables;
            this.tableOf = tableOf;
            this.groupOf = groupOf;
            this.batchSize = batchSize;
            int k = groupKeys.size();
            this.out = new Batch(k + calls.size());
            for (int j = 0; j < k; j++) {
                out.cols[j] = new Vec(groupKeys.get(j).type(), batchSize);
            }
            for (int a = 0; a < calls.size(); a++) {
                out.cols[k + a] = new Vec(calls.get(a).type(), batchSize);
            }
        }

        Batch next() {
            int groups = groupOf == null ? tables[0].groupCount() : groupOf.length;
            if (failed || next >= groups) {
                return null;
            }
            int n = Math.min(batchSize, groups - next);
            for (Vec v : out.cols) {
                v.nullMask(batchSize);
            }
            RuntimeException error = null;
            int produced = 0;
            for (int r = 0; r < n; r++) {
                Table table = groupOf == null ? tables[0] : tables[tableOf[next + r]];
                int g = groupOf == null ? next + r : groupOf[next + r];
                int k = table.keys.keyCount();
                try {
                    for (int a = 0; a < table.states.length; a++) {
                        out.cols[k + a].set(r, table.states[a].result(g));
                    }
                } catch (PolyQueryException e) {
                    if (!BatchExprs.deferrable(e)) {
                        throw e;
                    }
                    error = e;
                    failed = true;
                    break;
                }
                for (int j = 0; j < k; j++) {
                    table.keys.decode(g, j, out.cols[j], r);
                }
                produced++;
            }
            next += n;
            out.reset(produced);
            out.error = error;
            return out;
        }
    }

    /** Blocking hash aggregation (single-threaded). */
    static final class HashAggregate implements BatchOperator {
        private final BatchOperator input;
        private final List<BoundExpr> groupKeys;
        private final List<AggregateCall> calls;
        private final VecCompiler compiler;
        private final ExecContext ctx;
        private final int batchSize;
        private BatchExprs exprs;
        private Table table;
        private Emitter emitter;

        HashAggregate(BatchOperator input, List<BoundExpr> groupKeys, List<AggregateCall> calls, VecCompiler compiler,
                      ExecContext ctx, int batchSize) {
            this.input = input;
            this.groupKeys = groupKeys;
            this.calls = calls;
            this.compiler = compiler;
            this.ctx = ctx;
            this.batchSize = batchSize;
        }

        @Override
        public void open() {
            if (exprs == null) {
                exprs = new BatchExprs(compiler, inputs(groupKeys, calls));
            }
            if (table != null) {
                table.release();
            }
            table = new Table(groupKeys, calls, ctx);
            input.open();
            Batch b;
            while ((b = input.next()) != null) {
                ctx.checkNow();
                if (b.count > 0) {
                    Vec[] v = exprs.eval(b);
                    table.add(b, v);
                }
                if (b.error != null) {
                    throw b.error;
                }
            }
            emitter = new Emitter(table, groupKeys, calls, batchSize);
        }

        @Override
        public Batch next() {
            return emitter.next();
        }

        @Override
        public void close() {
            input.close();
            if (table != null) {
                table.release();
                table = null;
            }
            emitter = null;
        }
    }

    /** Streaming duplicate elimination: passes on the first occurrence of every row. */
    static final class Distinct implements BatchOperator {
        private final BatchOperator input;
        private final DataType[] types;
        private final ExecContext ctx;
        private final Batch out;
        private GroupKeys seen;
        private int[] gids = new int[0];
        private int[] sel = new int[0];
        private long reserved;

        Distinct(BatchOperator input, DataType[] types, ExecContext ctx) {
            this.input = input;
            this.types = types;
            this.ctx = ctx;
            this.out = new Batch(types.length);
        }

        @Override
        public void open() {
            seen = new GroupKeys(types);
            input.open();
        }

        @Override
        public Batch next() {
            Batch in;
            while ((in = input.next()) != null) {
                int m = 0;
                if (in.count > 0) {
                    if (gids.length < in.size) {
                        gids = new int[Math.max(in.size, 16)];
                        sel = new int[gids.length];
                    }
                    int before = seen.groupCount();
                    seen.groupIds(in.cols, in.sel, in.count, in.size, gids);
                    int expect = before;
                    for (int k = 0; k < in.count; k++) {
                        int i = in.pos(k);
                        if (gids[i] == expect) {
                            sel[m++] = i;
                            expect++;
                        }
                    }
                    long bytes = ColumnStore.estimate(in, sel, m) + 32L * m; // as the row engine estimates rows
                    ctx.reserve(bytes);
                    reserved += bytes;
                }
                out.cols = in.cols;
                out.size = in.size;
                out.sel = sel;
                out.count = m;
                out.error = in.error;
                if (m > 0 || out.error != null) {
                    return out;
                }
            }
            return null;
        }

        @Override
        public void close() {
            input.close();
            seen = null;
            ctx.release(reserved);
            reserved = 0;
        }
    }
}
