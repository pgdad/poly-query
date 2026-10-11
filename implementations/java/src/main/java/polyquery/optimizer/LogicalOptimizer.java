package polyquery.optimizer;

import java.util.List;
import polyquery.plan.LogicalPlan;

/**
 * Rule-based logical optimizer: applies a fixed sequence of {@link OptimizerRule}s, each once,
 * to a logical plan. It works on the logical plan only; access paths, join algorithms and the
 * execution model are chosen afterwards by physical planning.
 *
 * <p>Every rule preserves results <em>and errors</em>. Moving a predicate changes the rows the
 * others are evaluated on, so conjuncts move only if they precede every conjunct that may
 * raise an error — and, when such a conjunct exists, only if they can never be NULL (both
 * decided by {@link ExprSafety}, with column statistics). Predicates containing correlated
 * subqueries are never moved: their correlation frame is the row layout of the operator they
 * were bound against.
 */
public final class LogicalOptimizer {
    /** Applies no rules (query option {@code optimize: false}). */
    public static final LogicalOptimizer DISABLED = new LogicalOptimizer(List.of());

    /** The standard rule sequence (query option {@code optimize: true}). */
    public static final LogicalOptimizer STANDARD = new LogicalOptimizer(List.of(
            new ConstantFolding(),
            new PredicateSimplification(),
            new PredicatePushdown(),
            new JoinReorder(),
            new ProjectionPruning()));

    private final List<OptimizerRule> rules;

    public LogicalOptimizer(List<OptimizerRule> rules) {
        this.rules = List.copyOf(rules);
    }

    /** The optimizer for the query option {@code optimize}. */
    public static LogicalOptimizer forOption(boolean optimize) {
        return optimize ? STANDARD : DISABLED;
    }

    public List<OptimizerRule> rules() {
        return rules;
    }

    public LogicalPlan optimize(LogicalPlan plan) {
        for (OptimizerRule rule : rules) {
            plan = rule.apply(plan);
        }
        return plan;
    }
}
