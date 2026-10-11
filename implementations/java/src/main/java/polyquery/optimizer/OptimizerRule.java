package polyquery.optimizer;

import polyquery.plan.LogicalPlan;

/**
 * One logical rewrite. A rule maps a logical plan to an equivalent logical plan — same rows
 * and the same errors under every execution strategy — and takes no physical decisions.
 */
public interface OptimizerRule {
    /** Stable name of the rule (diagnostics, tests). */
    String name();

    LogicalPlan apply(LogicalPlan plan);
}
