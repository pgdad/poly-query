package polyquery.engine;

import polyquery.optimizer.LogicalOptimizer;
import polyquery.physical.PhysicalPlan;
import polyquery.physical.PhysicalPlanner;
import polyquery.physical.PhysicalQuery;
import polyquery.plan.LogicalPlan;

/**
 * The planning pipeline of one query: logical optimization (no rules with
 * {@code optimize: false}), then physical planning. Subqueries met in expressions go through
 * the same pipeline when the executor first needs them.
 */
final class QueryPlanner {
    private final LogicalOptimizer optimizer;
    private final PhysicalPlanner physical;

    /**
     * @param threads       worker threads the query may use
     * @param nativeKernels whether a native kernel library is loaded
     */
    QueryPlanner(QueryOptions opts, int threads, boolean nativeKernels) {
        this.optimizer = LogicalOptimizer.forOption(opts.optimize());
        this.physical = new PhysicalPlanner(new PhysicalPlanner.Options(opts.joinStrategy(), opts.useIndexes(),
                opts.optimize(), opts.mode(), threads, opts.useNative() && nativeKernels));
    }

    /** The physical plan and execution strategy of a query. */
    PhysicalQuery planQuery(LogicalPlan logical) {
        return physical.planQuery(optimizer.optimize(logical));
    }

    /** The physical plan of a query or subquery. */
    PhysicalPlan plan(LogicalPlan logical) {
        return physical.plan(optimizer.optimize(logical));
    }
}
