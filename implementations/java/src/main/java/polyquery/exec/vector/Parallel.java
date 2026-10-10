package polyquery.exec.vector;

import polyquery.physical.PhysicalPlan;

/** Parallel execution of pipelines (morsel-driven). */
final class Parallel {
    private Parallel() {
    }

    static BatchOperator tryBuild(BatchBuilder builder, PhysicalPlan plan) {
        return null;
    }
}
