package polyquery.physical;

import java.nio.file.Path;
import polyquery.engine.Engine;
import polyquery.engine.EngineConfig;
import polyquery.engine.LoadRequest;
import polyquery.engine.QueryOptions;
import polyquery.exec.ExecMode;
import polyquery.physical.PhysicalPlanner.JoinStrategy;
import polyquery.plan.LogicalPlan;

/** Physical planning decisions: access paths, join algorithms, top-N and the execution strategy. */
public final class PhysicalPlannerTest {
    private static final Engine ENGINE = engine();

    private PhysicalPlannerTest() {
    }

    private static Engine engine() {
        Engine e = new Engine(new EngineConfig(Path.of(".").toAbsolutePath(), true, 1L << 30, 1L << 30,
                1_000_000, 1_000_000, 1, null));
        StringBuilder t = new StringBuilder("id,grp\n");
        for (int i = 1; i <= 100; i++) {
            t.append(i).append(',').append(i % 4).append('\n');
        }
        e.load(new LoadRequest("t", "csv", null, t.toString(), null, true, ',', false));
        e.load(new LoadRequest("u", "csv", null, "grp,label\n0,a\n1,b\n2,c\n3,d\n", null, true, ',', false));
        e.query("CREATE INDEX t_id ON t (id)", QueryOptions.DEFAULT);
        return e;
    }

    private static PhysicalPlanner planner(JoinStrategy join, boolean useIndexes, boolean topN) {
        return new PhysicalPlanner(new PhysicalPlanner.Options(join, useIndexes, topN, ExecMode.VECTORIZED, 1, false));
    }

    private static PhysicalPlan plan(PhysicalPlanner planner, String sql) {
        return planner.plan(ENGINE.logicalPlan(sql));
    }

    /** True if some node of the plan is an instance of {@code op}. */
    private static boolean contains(PhysicalPlan plan, Class<? extends PhysicalPlan> op) {
        return op.isInstance(plan) || plan.children().stream().anyMatch(c -> contains(c, op));
    }

    private static void check(boolean cond, String msg) {
        if (!cond) {
            throw new AssertionError(msg);
        }
    }

    public static void testAccessPath() {
        String sql = "SELECT grp FROM t WHERE id = 7";
        check(contains(plan(planner(JoinStrategy.AUTO, true, true), sql), PhysicalPlan.IndexScan.class),
                "selective equality on an indexed column uses the index");
        check(!contains(plan(planner(JoinStrategy.AUTO, false, true), sql), PhysicalPlan.IndexScan.class),
                "use_indexes: false");
        check(!contains(plan(planner(JoinStrategy.AUTO, true, true), "SELECT grp FROM t WHERE id > 2"),
                PhysicalPlan.IndexScan.class), "non-selective range scans the table");
    }

    public static void testJoinAlgorithmFollowsOption() {
        String sql = "SELECT t.id, u.label FROM t JOIN u ON u.grp = t.grp";
        check(contains(plan(planner(JoinStrategy.AUTO, true, true), sql), PhysicalPlan.HashJoin.class), "auto");
        check(contains(plan(planner(JoinStrategy.MERGE, true, true), sql), PhysicalPlan.MergeJoin.class), "merge");
        check(contains(plan(planner(JoinStrategy.NESTED_LOOP, true, true), sql), PhysicalPlan.NestedLoopJoin.class),
                "nested_loop");
        check(contains(plan(planner(JoinStrategy.HASH, true, true), "SELECT t.id FROM t JOIN u ON u.grp < t.grp"),
                PhysicalPlan.NestedLoopJoin.class), "joins without equi keys are nested-loop joins");
    }

    public static void testHashJoinBuildsOnSmallerInput() {
        PhysicalPlan p = plan(planner(JoinStrategy.HASH, true, true), "SELECT t.id FROM u JOIN t ON u.grp = t.grp");
        while (!(p instanceof PhysicalPlan.HashJoin)) {
            p = p.children().getFirst();
        }
        check(((PhysicalPlan.HashJoin) p).buildLeft(), "u (4 rows) is the build side");
    }

    public static void testTopNOnlyWhenEnabled() {
        String sql = "SELECT id FROM t ORDER BY grp, id LIMIT 3";
        check(contains(plan(planner(JoinStrategy.AUTO, true, true), sql), PhysicalPlan.TopN.class), "top-N");
        check(!contains(plan(planner(JoinStrategy.AUTO, true, false), sql), PhysicalPlan.TopN.class), "full sort");
    }

    public static void testExecutionStrategy() {
        LogicalPlan logical = ENGINE.logicalPlan("SELECT grp, COUNT(*) FROM t GROUP BY grp");
        PhysicalQuery row = new PhysicalPlanner(new PhysicalPlanner.Options(JoinStrategy.AUTO, true, true,
                ExecMode.ROW, 4, true)).planQuery(logical);
        check(row.mode() == ExecMode.ROW && row.threads() == 1 && !row.nativeKernels(),
                "the row engine is single-threaded and uses no native kernels: " + row);
        PhysicalQuery vectorized = new PhysicalPlanner(new PhysicalPlanner.Options(JoinStrategy.AUTO, true, true,
                ExecMode.VECTORIZED, 4, true)).planQuery(logical);
        check(vectorized.mode() == ExecMode.VECTORIZED && vectorized.threads() == 4 && vectorized.nativeKernels(),
                "vectorized: " + vectorized);
    }
}
