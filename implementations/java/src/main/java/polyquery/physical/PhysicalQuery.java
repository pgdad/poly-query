package polyquery.physical;

import polyquery.exec.ExecMode;

/**
 * A physically planned query: the operator tree and the execution strategy chosen for it.
 *
 * @param root          the operator tree (what {@code EXPLAIN} shows; the same in both modes)
 * @param mode          execution model
 * @param threads       worker threads for parallel pipelines (1 for the row engine)
 * @param nativeKernels whether supported vectorized operations call the native kernels
 */
public record PhysicalQuery(PhysicalPlan root, ExecMode mode, int threads, boolean nativeKernels) {
}
