package polyquery.exec.vector;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.exec.ExecContext;
import polyquery.exec.ExpressionCompiler;
import polyquery.physical.PhysicalPlan;
import polyquery.plan.AggregateCall;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;

/**
 * Morsel-driven parallel execution of pipelines: a table scan followed by filters, projections
 * and hash-join probes (whose hash tables are built first and then shared read-only). The
 * scan's row groups are cut into morsels handed out to worker threads in scan order.
 *
 * <p>Results are identical to sequential execution. Parallel aggregation merges per-worker
 * partial tables exactly (integer/DECIMAL sums never round) and emits groups in order of
 * their first appearance in scan order; other pipelines are gathered in morsel order. Errors
 * are reported as sequential execution would: a data error of morsel m is raised only after
 * the results of all earlier morsels (later morsels are abandoned).
 */
final class Parallel {
    /** Shared worker threads (daemon, large stacks for deeply nested expressions). */
    private static final ExecutorService POOL = Executors.newCachedThreadPool(new ThreadFactory() {
        private final AtomicInteger seq = new AtomicInteger();

        @Override
        public Thread newThread(Runnable r) {
            Thread t = new Thread(null, r, "polyquery-worker-" + seq.incrementAndGet(), 256L << 20);
            t.setDaemon(true);
            return t;
        }
    });

    private Parallel() {
    }

    /** A pipeline: a table scan and the streaming operators above it (bottom-up). */
    record Chain(PhysicalPlan.TableScan scan, List<PhysicalPlan> stages) {
        /** True if some expression of the pipeline may raise a data error. */
        boolean canFail() {
            for (PhysicalPlan stage : stages) {
                for (BoundExpr e : PhysicalPlan.expressions(stage)) {
                    if (polyquery.optimizer.LogicalOptimizer.canFail(e)) {
                        return true;
                    }
                }
            }
            return false;
        }

        /** The hash joins of the chain, outermost first (the order the row engine builds them). */
        List<PhysicalPlan.HashJoin> joinsTopDown() {
            List<PhysicalPlan.HashJoin> out = new ArrayList<>();
            for (int i = stages.size() - 1; i >= 0; i--) {
                if (stages.get(i) instanceof PhysicalPlan.HashJoin j) {
                    out.add(j);
                }
            }
            return out;
        }
    }

    /** Expressions workers can evaluate concurrently: no subqueries and no correlation. */
    private static boolean safe(BoundExpr e) {
        return e == null || !BoundExprs.any(e, x -> x instanceof BoundExpr.OuterRef || BoundExprs.subqueryOf(x) != null);
    }

    private static boolean safe(List<BoundExpr> exprs) {
        for (BoundExpr e : exprs) {
            if (!safe(e)) {
                return false;
            }
        }
        return true;
    }

    /** The pipeline rooted at {@code plan}, or null if it is not one that workers can run. */
    static Chain chain(PhysicalPlan plan) {
        List<PhysicalPlan> stages = new ArrayList<>();
        PhysicalPlan p = plan;
        while (true) {
            switch (p) {
                case PhysicalPlan.TableScan s -> {
                    java.util.Collections.reverse(stages);
                    return new Chain(s, stages);
                }
                case PhysicalPlan.Filter f -> {
                    if (!safe(f.predicate())) {
                        return null;
                    }
                    stages.add(f);
                    p = f.input();
                }
                case PhysicalPlan.Project pr -> {
                    if (!safe(pr.expressions())) {
                        return null;
                    }
                    stages.add(pr);
                    p = pr.input();
                }
                case PhysicalPlan.HashJoin j -> {
                    if (!safe(j.leftKeys()) || !safe(j.rightKeys()) || !safe(j.residual())) {
                        return null;
                    }
                    stages.add(j);
                    p = j.buildLeft() ? j.right() : j.left();
                }
                default -> {
                    return null;
                }
            }
        }
    }

    /** A parallel operator for {@code plan}, or null if it should run sequentially. */
    static BatchOperator tryBuild(BatchBuilder builder, PhysicalPlan plan) {
        if (plan instanceof PhysicalPlan.HashAggregate a) {
            Chain c = chain(a.input());
            if (c != null && safe(a.groupKeys()) && aggregatesSafe(a.aggregates())
                    && worthIt(c, builder.morselRows())) {
                return new Aggregate(builder, c, a);
            }
            return null;
        }
        if (plan instanceof PhysicalPlan.TableScan) {
            return null; // a bare scan is just copying: no gain from threads
        }
        if (plan instanceof PhysicalPlan.HashDistinct d) {
            Chain c = chain(d.input());
            if (c == null || !worthIt(c, builder.morselRows())) {
                return null;
            }
            if (!c.canFail() && c.scan().table().data() instanceof polyquery.storage.ColumnarData) {
                // Nothing can fail, so a blocking DISTINCT is indistinguishable from the streaming
                // one: a keys-only parallel aggregation (groups in order of first appearance).
                List<BoundExpr> keys = new ArrayList<>();
                List<polyquery.storage.ColumnSchema> in = d.input().schema();
                for (int i = 0; i < in.size(); i++) {
                    keys.add(new BoundExpr.ColumnRef(i, in.get(i).type(), in.get(i).name()));
                }
                return new Aggregate(builder, c, new PhysicalPlan.HashAggregate(d.input(), keys, List.of()));
            }
            // workers drop duplicates within their morsels; the final DISTINCT streams over the rest
            return new AggregateBatches.Distinct(new Gather(builder, c, new DistinctReducer(
                    BatchBuilder.types(d.schema()))), BatchBuilder.types(d.schema()), builder.context());
        }
        if (plan instanceof PhysicalPlan.TopN t) {
            // workers keep the best rows of their morsels; the final top-N picks among them
            Chain c = chain(t.input());
            if (c == null || !worthIt(c, builder.morselRows())) {
                return null;
            }
            long offset = t.offset() == null ? 0 : builder.rows().constant(t.offset(), "OFFSET", 0);
            long limit = builder.rows().constant(t.limit(), "LIMIT", -1);
            if (limit < 0 || offset + limit > MAX_PARALLEL_TOP_N) {
                return null;
            }
            return new SortBatches.Sort(new Gather(builder, c, new TopNReducer(t.keys(), t.input().schema(),
                    (int) (offset + limit))), t.keys(), t.schema(), builder.context(), builder.batchSize(), offset,
                    limit);
        }
        Chain c = chain(plan);
        if (c != null && worthIt(c, builder.morselRows())) {
            return new Gather(builder, c, null);
        }
        return null;
    }

    /** Largest OFFSET + LIMIT for which top-N is pre-computed per morsel. */
    private static final long MAX_PARALLEL_TOP_N = 100_000;

    /**
     * An order-preserving reduction of one morsel's output, applied by the worker before the
     * batches are handed to the (sequential) consumer.
     */
    interface Reducer {
        /** Fresh per-morsel state. */
        MorselReduction start(int width, ExecContext ctx);
    }

    /** The reduction state of one morsel: fed with the pipeline's batches, then finished. */
    interface MorselReduction {
        void add(Batch b);

        List<Batch> finish();
    }

    /** Keeps the first occurrence of every row within the morsel. */
    private record DistinctReducer(polyquery.types.DataType[] types) implements Reducer {
        @Override
        public MorselReduction start(int width, ExecContext ctx) {
            GroupKeys seen = new GroupKeys(types);
            List<Batch> out = new ArrayList<>();
            return new MorselReduction() {
                private int[] gids = new int[0];
                private int[] keep = new int[0];

                @Override
                public void add(Batch b) {
                    if (gids.length < b.size) {
                        gids = new int[b.size];
                        keep = new int[b.size];
                    }
                    int before = seen.groupCount();
                    seen.groupIds(b.cols, b.sel, b.count, b.size, gids);
                    int m = 0;
                    for (int k = 0; k < b.count; k++) {
                        int i = b.pos(k);
                        if (gids[i] == before + m) {
                            keep[m++] = i;
                        }
                    }
                    if (m > 0) {
                        Batch copy = new Batch(width);
                        for (int c = 0; c < width; c++) {
                            if (b.cols[c] != null) {
                                copy.cols[c] = Vec.compact(b.cols[c], keep, m);
                            }
                        }
                        copy.reset(m);
                        out.add(copy);
                    }
                }

                @Override
                public List<Batch> finish() {
                    return out;
                }
            };
        }
    }

    /** Keeps the best {@code keep} rows of the morsel (stable: ties in morsel order), in sort order. */
    private record TopNReducer(List<polyquery.plan.SortKey> keys, List<polyquery.storage.ColumnSchema> schema,
                               int keep) implements Reducer {
        @Override
        public MorselReduction start(int width, ExecContext ctx) {
            ColumnStore store = new ColumnStore(schema);
            return new MorselReduction() {
                private int[] all = new int[0];

                @Override
                public void add(Batch b) {
                    if (all.length < b.count) {
                        all = new int[b.count];
                    }
                    for (int k = 0; k < b.count; k++) {
                        all[k] = b.pos(k);
                    }
                    store.append(b, all, b.count);
                }

                @Override
                public List<Batch> finish() {
                    int[] perm = SortBatches.sort(store, keys, ctx);
                    int n = Math.min(keep, perm.length);
                    if (n == 0) {
                        return List.of();
                    }
                    Batch out = new Batch(width);
                    for (int c = 0; c < width; c++) {
                        Vec src = store.column(c);
                        if (src != null) {
                            Vec dst = new Vec(src.type, n);
                            dst.nullMask(n);
                            ColumnStore.gather(src, perm, 0, n, dst, 0);
                            dst.hasNulls = src.hasNulls;
                            out.cols[c] = dst;
                        }
                    }
                    out.reset(n);
                    return List.of(out);
                }
            };
        }
    }

    private static boolean aggregatesSafe(List<AggregateCall> calls) {
        for (AggregateCall c : calls) {
            if (c.distinct() || !safe(c.argument())) {
                return false; // DISTINCT states are not merged
            }
            if (!AggState.create(c).mergeable()) {
                return false;
            }
        }
        return true;
    }

    private static boolean worthIt(Chain c, int morselRows) {
        return Morsel.of(c.scan(), morselRows).size() >= 2;
    }

    /** Runs independent tasks on the worker pool (the first on the calling thread) and waits for all. */
    static void runAll(List<Runnable> tasks, ExecContext ctx) {
        List<Future<?>> futures = new ArrayList<>();
        for (int i = 1; i < tasks.size(); i++) {
            futures.add(POOL.submit(tasks.get(i)));
        }
        RuntimeException failure = null;
        try {
            tasks.getFirst().run();
        } catch (RuntimeException e) {
            failure = e;
        }
        for (Future<?> f : futures) {
            try {
                await(f, ctx);
            } catch (RuntimeException e) {
                if (failure == null) {
                    failure = e;
                }
            }
        }
        if (failure != null) {
            throw failure;
        }
    }

    /** Rethrows a worker's failure on the query thread. */
    private static RuntimeException unwrap(Throwable t) {
        if (t instanceof ExecutionException e && e.getCause() != null) {
            t = e.getCause();
        }
        if (t instanceof RuntimeException r) {
            return r;
        }
        if (t instanceof StackOverflowError) {
            return new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "expression nesting too deep");
        }
        if (t instanceof OutOfMemoryError) {
            return new PolyQueryException(ErrorCode.RESOURCE_LIMIT, "out of memory");
        }
        if (t instanceof Error e) {
            throw e;
        }
        return new IllegalStateException(t);
    }

    /** Waits for a worker result, observing the query's timeout and cancellation meanwhile. */
    private static <T> T await(Future<T> f, ExecContext ctx) {
        while (true) {
            try {
                return f.get(20, TimeUnit.MILLISECONDS);
            } catch (TimeoutException e) {
                ctx.checkNow();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new PolyQueryException(ErrorCode.CANCELLED, "query was interrupted");
            } catch (ExecutionException e) {
                throw unwrap(e);
            }
        }
    }

    /** Shared per-query parts of a parallel pipeline: prebuilt join tables and join counters. */
    private static final class Shared {
        final Chain chain;
        final BatchBuilder builder;
        final List<PhysicalPlan.HashJoin> joins = new ArrayList<>();
        final List<JoinBatches.JoinTable> tables = new ArrayList<>();
        final List<JoinBatches.JoinCounter> counters = new ArrayList<>();

        Shared(BatchBuilder builder, Chain chain) {
            this.builder = builder;
            this.chain = chain;
        }

        /** Builds the hash tables of the chain's joins (outermost first, like the row engine). */
        void open() {
            release();
            ExecContext ctx = builder.context();
            for (PhysicalPlan.HashJoin j : chain.joinsTopDown()) {
                boolean left = j.buildLeft();
                List<BoundExpr> buildKeys = left ? j.leftKeys() : j.rightKeys();
                List<BoundExpr> probeKeys = left ? j.rightKeys() : j.leftKeys();
                PhysicalPlan buildPlan = left ? j.left() : j.right();
                JoinBatches.JoinTable t = new JoinBatches.JoinTable(buildPlan.schema(), ctx);
                t.build(builder.build(buildPlan), new BatchExprs(builder.compiler(), buildKeys),
                        JoinBatches.scaleFactors(buildKeys, probeKeys), keyTypes(buildKeys),
                        BatchBuilder.expectedRows(buildPlan), builder.threads());
                joins.add(j);
                tables.add(t);
                counters.add(new JoinBatches.JoinCounter(ctx.maxJoinRows()));
            }
        }

        void release() {
            for (JoinBatches.JoinTable t : tables) {
                t.release();
            }
            joins.clear();
            tables.clear();
            counters.clear();
        }

        private static polyquery.types.DataType[] keyTypes(List<BoundExpr> keys) {
            polyquery.types.DataType[] out = new polyquery.types.DataType[keys.size()];
            for (int i = 0; i < out.length; i++) {
                out[i] = keys.get(i).type();
            }
            return out;
        }

        /** A private instance of the pipeline for one worker (own compiled expressions and buffers). */
        Pipeline instantiate() {
            ExecContext ctx = builder.context();
            ExpressionCompiler rowCompiler = new ExpressionCompiler(ctx, plan -> {
                throw new IllegalStateException("subquery in a parallel pipeline");
            });
            VecCompiler comp = new VecCompiler(ctx, rowCompiler);
            ScanBatches.TableScan scan = new ScanBatches.TableScan(chain.scan(), ctx, builder.batchSize(),
                    List.of());
            BatchOperator op = scan;
            for (PhysicalPlan stage : chain.stages()) {
                op = switch (stage) {
                    case PhysicalPlan.Filter f -> new BatchOperators.Filter(op, comp, f.predicate(),
                            f.schema().size());
                    case PhysicalPlan.Project p -> new BatchOperators.Project(op, comp, p.expressions());
                    case PhysicalPlan.HashJoin j -> {
                        int idx = joins.indexOf(j);
                        yield builder.hashJoin(j, op, tables.get(idx), comp, counters.get(idx));
                    }
                    default -> throw new IllegalStateException("not a pipeline stage: " + stage);
                };
            }
            return new Pipeline(scan, op, comp);
        }
    }

    /** One worker's instance of a pipeline. */
    record Pipeline(ScanBatches.TableScan scan, BatchOperator top, VecCompiler compiler) {
        void start(Morsel m) {
            scan.setMorsel(m);
            top.open();
        }
    }

    /** First data error by morsel index, plus a fatal error that stops everything. */
    private static final class Errors {
        private int morsel = Integer.MAX_VALUE;
        private RuntimeException error;
        private volatile RuntimeException fatal;
        final AtomicBoolean stop = new AtomicBoolean();

        synchronized void data(int m, RuntimeException e) {
            if (m < morsel) {
                morsel = m;
                error = e;
            }
        }

        synchronized int firstMorsel() {
            return morsel;
        }

        synchronized RuntimeException firstError() {
            return error;
        }

        void fatal(RuntimeException e) {
            if (fatal == null) {
                fatal = e;
            }
            stop.set(true);
        }
    }

    // ------------------------------------------------------------------ aggregation

    /**
     * Parallel hash aggregation: every worker aggregates whole morsels into a private partial
     * table, recording for each group the position (morsel, row) of its first row; the partial
     * tables are merged exactly and the groups emitted in order of first appearance.
     */
    static final class Aggregate implements BatchOperator {
        private final Shared shared;
        private final PhysicalPlan.HashAggregate plan;
        private final ExecContext ctx;
        private final int threads;
        private final List<AggregateBatches.Table> merged = new ArrayList<>();
        private AggregateBatches.Emitter emitter;
        private final List<AggregateBatches.Table> partials = new ArrayList<>();

        Aggregate(BatchBuilder builder, Chain chain, PhysicalPlan.HashAggregate plan) {
            this.shared = new Shared(builder, chain);
            this.plan = plan;
            this.ctx = builder.context();
            this.threads = builder.threads();
        }

        /**
         * A worker's result: partial table, first positions of its groups and, per merge
         * partition, its group ids in ascending order.
         */
        private record Partial(AggregateBatches.Table table, long[] first, int[][] byPartition) {
        }

        /** Number of hash partitions merged in parallel. */
        private int partitions() {
            return plan.groupKeys().isEmpty() ? 1 : Math.min(64, Math.max(1, threads));
        }

        /** Group ids of a partial table per merge partition (each list ascending, i.e. in first-position order). */
        private int[][] partitionGroups(AggregateBatches.Table table, int parts) {
            int groups = table.groupCount();
            int[] partOf = new int[groups];
            int[] counts = new int[parts];
            for (int g = 0; g < groups; g++) {
                partOf[g] = parts == 1 ? 0 : partition(table.keys.hash(g), parts);
                counts[partOf[g]]++;
            }
            int[][] out = new int[parts][];
            for (int p = 0; p < parts; p++) {
                out[p] = new int[counts[p]];
            }
            int[] fill = new int[parts];
            for (int g = 0; g < groups; g++) {
                out[partOf[g]][fill[partOf[g]]++] = g;
            }
            return out;
        }

        @Override
        public void open() {
            close();
            shared.open();
            List<Morsel> morsels = Morsel.of(shared.chain.scan(), shared.builder.morselRows());
            AtomicInteger next = new AtomicInteger();
            Errors errors = new Errors();
            int workers = Math.max(1, Math.min(threads, morsels.size()));
            List<Future<Partial>> futures = new ArrayList<>();
            for (int w = 1; w < workers; w++) {
                futures.add(POOL.submit(() -> work(morsels, next, errors)));
            }
            List<Partial> results = new ArrayList<>();
            try {
                results.add(work(morsels, next, errors));
            } catch (RuntimeException | Error e) {
                errors.fatal(e instanceof RuntimeException r ? r : unwrap(e));
            }
            for (Future<Partial> f : futures) {
                try {
                    results.add(await(f, ctx));
                } catch (RuntimeException e) {
                    errors.fatal(e);
                }
            }
            for (Partial p : results) {
                if (p != null) {
                    partials.add(p.table());
                }
            }
            if (errors.fatal != null) {
                throw errors.fatal;
            }
            if (errors.firstError() != null) {
                throw errors.firstError();
            }
            merge(results);
        }

        private Partial work(List<Morsel> morsels, AtomicInteger next, Errors errors) {
            Pipeline pipe = shared.instantiate();
            AggregateBatches.Table table = new AggregateBatches.Table(plan.groupKeys(), plan.aggregates(), ctx);
            BatchExprs exprs = new BatchExprs(pipe.compiler(),
                    AggregateBatches.inputs(plan.groupKeys(), plan.aggregates()));
            long[] first = new long[16];
            Arrays.fill(first, Long.MAX_VALUE);
            try {
                int m;
                while (!errors.stop.get() && (m = next.getAndIncrement()) < morsels.size()) {
                    if (m > errors.firstMorsel()) {
                        break; // an earlier morsel already failed
                    }
                    pipe.start(morsels.get(m));
                    long seq = 0;
                    try {
                        Batch b;
                        while ((b = pipe.top().next()) != null) {
                            ctx.checkNow();
                            if (b.count > 0) {
                                Vec[] v = exprs.eval(b);
                                int before = table.groupCount();
                                int[] gids = table.add(b, v);
                                if (table.groupCount() > before) {
                                    if (first.length < table.groupCount()) {
                                        int old = first.length;
                                        first = Arrays.copyOf(first, Math.max(table.groupCount(), old * 2));
                                        Arrays.fill(first, old, first.length, Long.MAX_VALUE);
                                    }
                                    for (int k = 0; k < b.count; k++) {
                                        int g = gids[b.pos(k)];
                                        if (g >= before && first[g] == Long.MAX_VALUE) {
                                            first[g] = ((long) m << 32) | (seq + k);
                                        }
                                    }
                                }
                                seq += b.count;
                            }
                            if (b.error != null) {
                                errors.data(m, b.error);
                                break;
                            }
                        }
                    } catch (PolyQueryException e) {
                        if (!BatchExprs.deferrable(e)) {
                            throw e;
                        }
                        errors.data(m, e); // e.g. a corrupt chunk of this morsel
                    } finally {
                        pipe.top().close();
                    }
                }
            } catch (RuntimeException e) {
                errors.fatal(e);
                throw e;
            }
            return new Partial(table, first, partitionGroups(table, partitions()));
        }

        /** Partition (of {@code parts}) of a group hash. */
        private static int partition(long hash, int parts) {
            return (int) (((hash >>> 32) * parts) >>> 32);
        }

        /** A merged partition: table and first positions of its groups (ascending by group id). */
        private record Merged(AggregateBatches.Table table, long[] first) {
        }

        /**
         * Merges the partial tables. Groups are split into hash partitions merged in parallel;
         * within a partition, the partials' groups are merged in order of first position (a
         * k-way merge, as each partial lists its groups in that order), so merged group ids are
         * in first-appearance order; the output interleaves the partitions the same way.
         */
        private void merge(List<Partial> results) {
            long total = 0;
            for (Partial p : results) {
                total += p.table().groupCount();
            }
            int parts = total < 16_384 ? 1 : partitions();
            List<Future<Merged>> futures = new ArrayList<>();
            for (int part = 1; part < parts; part++) {
                int pp = part;
                futures.add(POOL.submit(() -> mergePartition(results, pp, parts)));
            }
            List<Merged> merged = new ArrayList<>();
            merged.add(mergePartition(results, 0, parts));
            for (Future<Merged> f : futures) {
                merged.add(await(f, ctx));
            }
            AggregateBatches.Table[] tables = new AggregateBatches.Table[parts];
            long[][] firsts = new long[parts][];
            int groups = 0;
            for (int part = 0; part < parts; part++) {
                tables[part] = merged.get(part).table();
                firsts[part] = merged.get(part).first();
                this.merged.add(tables[part]);
                groups += tables[part].groupCount();
            }
            int[] tableOf = new int[groups];
            int[] groupOf = new int[groups];
            int[] sizes = new int[parts];
            for (int part = 0; part < parts; part++) {
                sizes[part] = tables[part].groupCount();
            }
            kWayMerge(firsts, sizes, (src, g, i) -> {
                tableOf[i] = src;
                groupOf[i] = g;
            });
            emitter = new AggregateBatches.Emitter(tables, tableOf, groupOf, plan.groupKeys(), plan.aggregates(),
                    shared.builder.batchSize());
        }

        private Merged mergePartition(List<Partial> results, int part, int parts) {
            AggregateBatches.Table table = new AggregateBatches.Table(plan.groupKeys(), plan.aggregates(), ctx);
            int k = results.size();
            int[][] members = new int[k][];
            long[][] firsts = new long[k][];
            int[] sizes = new int[k];
            for (int w = 0; w < k; w++) {
                Partial p = results.get(w);
                int[] ids;
                if (parts == 1) {
                    ids = new int[p.table().groupCount()];
                    for (int g = 0; g < ids.length; g++) {
                        ids[g] = g;
                    }
                } else {
                    ids = p.byPartition()[part];
                }
                long[] first = new long[ids.length];
                for (int i = 0; i < ids.length; i++) {
                    first[i] = p.first()[ids[i]];
                }
                members[w] = ids;
                firsts[w] = first;
                sizes[w] = ids.length;
            }
            int bound = 0;
            for (int size : sizes) {
                bound += size;
            }
            table.ensureCapacity(bound);
            long[][] out = {new long[Math.max(16, bound)]};
            kWayMerge(firsts, sizes, (w, idx, i) -> {
                int before = table.groupCount();
                int to = table.merge(results.get(w).table(), members[w][idx]);
                if (table.groupCount() > before) {
                    if (out[0].length <= to) {
                        out[0] = Arrays.copyOf(out[0], Math.max(to + 1, out[0].length * 2));
                    }
                    out[0][to] = firsts[w][idx];
                }
            });
            ctx.checkNow();
            return new Merged(table, out[0]);
        }

        @Override
        public Batch next() {
            return emitter.next();
        }

        @Override
        public void close() {
            for (AggregateBatches.Table t : partials) {
                t.release();
            }
            partials.clear();
            for (AggregateBatches.Table t : merged) {
                t.release();
            }
            merged.clear();
            emitter = null;
            shared.release();
        }
    }

    /** Receives the elements of a k-way merge: source, index within the source, output position. */
    interface MergeSink {
        void accept(int source, int index, int position);
    }

    /**
     * Merges k ascending sequences of positions ({@code keys[s][0 .. sizes[s])}) and passes the
     * elements to {@code sink} in ascending order (ties: lower source first).
     */
    static void kWayMerge(long[][] keys, int[] sizes, MergeSink sink) {
        int k = keys.length;
        int[] heap = new int[k];
        int[] cursor = new int[k];
        int n = 0;
        for (int s = 0; s < k; s++) {
            if (sizes[s] > 0) {
                heap[n++] = s;
                siftUp(heap, n - 1, keys, cursor);
            }
        }
        int out = 0;
        while (n > 0) {
            int s = heap[0];
            sink.accept(s, cursor[s], out++);
            if (++cursor[s] < sizes[s]) {
                siftDown(heap, n, keys, cursor);
            } else {
                heap[0] = heap[--n];
                siftDown(heap, n, keys, cursor);
            }
        }
    }

    private static boolean less(int a, int b, long[][] keys, int[] cursor) {
        long x = keys[a][cursor[a]];
        long y = keys[b][cursor[b]];
        return x < y || x == y && a < b;
    }

    private static void siftUp(int[] heap, int i, long[][] keys, int[] cursor) {
        while (i > 0) {
            int parent = (i - 1) >>> 1;
            if (!less(heap[i], heap[parent], keys, cursor)) {
                return;
            }
            int t = heap[i];
            heap[i] = heap[parent];
            heap[parent] = t;
            i = parent;
        }
    }

    private static void siftDown(int[] heap, int n, long[][] keys, int[] cursor) {
        int i = 0;
        while (true) {
            int l = 2 * i + 1;
            if (l >= n) {
                return;
            }
            int c = l + 1 < n && less(heap[l + 1], heap[l], keys, cursor) ? l + 1 : l;
            if (!less(heap[c], heap[i], keys, cursor)) {
                return;
            }
            int t = heap[i];
            heap[i] = heap[c];
            heap[c] = t;
            i = c;
        }
    }

    // ------------------------------------------------------------------ gather

    /**
     * Runs a pipeline over morsels on worker threads and returns its batches in morsel order,
     * keeping a bounded number of morsels in flight.
     */
    static final class Gather implements BatchOperator {
        private final Shared shared;
        private final ExecContext ctx;
        private final int threads;
        private final int width;
        private final ConcurrentLinkedQueue<Pipeline> idle = new ConcurrentLinkedQueue<>();
        private final ArrayDeque<Future<MorselOutput>> inFlight = new ArrayDeque<>();
        private List<Morsel> morsels;
        private int submitted;
        private MorselOutput current;
        private int index;
        private AtomicBoolean cancelled = new AtomicBoolean();
        private final AtomicLong reservedBytes = new AtomicLong();
        private boolean done;

        private final Reducer reducer;

        /** @param reducer per-morsel reduction applied by the workers, or null */
        Gather(BatchBuilder builder, Chain chain, Reducer reducer) {
            this.shared = new Shared(builder, chain);
            this.ctx = builder.context();
            this.threads = builder.threads();
            this.width = widthOf(chain);
            this.reducer = reducer;
        }

        private static int widthOf(Chain c) {
            return c.stages().isEmpty() ? c.scan().schema().size()
                    : c.stages().getLast().schema().size();
        }

        /** The batches of one morsel (compacted copies) and the error raised after them, if any. */
        private record MorselOutput(List<Batch> batches, RuntimeException error, long bytes) {
        }

        @Override
        public void open() {
            close();
            cancelled = new AtomicBoolean();
            shared.open();
            idle.clear();
            morsels = Morsel.of(shared.chain.scan(), shared.builder.morselRows());
            submitted = 0;
            current = null;
            index = 0;
            done = false;
            int window = Math.max(2, Math.min(threads, morsels.size()) * 2);
            while (submitted < morsels.size() && inFlight.size() < window) {
                submit();
            }
        }

        private void submit() {
            Morsel m = morsels.get(submitted++);
            AtomicBoolean stop = cancelled;
            inFlight.add(POOL.submit(() -> run(m, stop)));
        }

        private MorselOutput run(Morsel m, AtomicBoolean stop) {
            if (stop.get()) {
                return new MorselOutput(List.of(), null, 0);
            }
            Pipeline pipe = idle.poll();
            if (pipe == null) {
                pipe = shared.instantiate();
            }
            List<Batch> out = new ArrayList<>();
            RuntimeException error = null;
            long bytes = 0;
            MorselReduction reduction = reducer == null ? null : reducer.start(width, ctx);
            pipe.start(m);
            try {
                Batch b;
                while (!stop.get() && (b = pipe.top().next()) != null) {
                    ctx.checkNow();
                    if (b.count > 0 && reduction != null) {
                        reduction.add(b);
                    } else if (b.count > 0) {
                        Batch copy = new Batch(width);
                        for (int c = 0; c < width; c++) {
                            if (b.cols[c] != null) {
                                copy.cols[c] = Vec.compact(b.cols[c], b.sel, b.count);
                            }
                        }
                        copy.reset(b.count);
                        long size = 16L + (long) b.count * 9 * width;
                        ctx.reserve(size);
                        bytes += size;
                        out.add(copy);
                    }
                    if (b.error != null) {
                        error = b.error;
                        break;
                    }
                }
            } catch (PolyQueryException e) {
                if (!BatchExprs.deferrable(e)) {
                    throw e;
                }
                error = e;
            } finally {
                pipe.top().close();
            }
            idle.add(pipe);
            if (reduction != null) {
                out = reduction.finish();
                for (Batch r : out) {
                    long size = 16L + (long) r.count * 9 * width;
                    ctx.reserve(size);
                    bytes += size;
                }
            }
            reservedBytes.addAndGet(bytes);
            return new MorselOutput(out, error, bytes);
        }

        @Override
        public Batch next() {
            while (!done) {
                if (current != null && index < current.batches().size()) {
                    return current.batches().get(index++);
                }
                if (current != null) {
                    ctx.release(current.bytes());
                    reservedBytes.addAndGet(-current.bytes());
                    if (current.error() != null) {
                        done = true;
                        Batch b = new Batch(width);
                        b.reset(0);
                        b.error = current.error();
                        return b;
                    }
                    current = null;
                }
                Future<MorselOutput> f = inFlight.poll();
                if (f == null) {
                    done = true;
                    break;
                }
                current = await(f, ctx);
                index = 0;
                if (submitted < morsels.size()) {
                    submit();
                }
            }
            return null;
        }

        @Override
        public void close() {
            cancelled.set(true);
            for (Future<MorselOutput> f : inFlight) {
                try {
                    f.get();
                } catch (ExecutionException | RuntimeException e) {
                    // abandoned morsel: its error is irrelevant
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
            inFlight.clear();
            ctx.release(reservedBytes.getAndSet(0));
            current = null;
            shared.release();
        }
    }
}
