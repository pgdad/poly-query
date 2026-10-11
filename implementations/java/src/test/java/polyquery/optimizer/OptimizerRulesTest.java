package polyquery.optimizer;

import java.nio.file.Path;
import java.util.List;
import polyquery.engine.Engine;
import polyquery.engine.EngineConfig;
import polyquery.engine.LoadRequest;
import polyquery.plan.LogicalPlan;
import polyquery.plan.LogicalPlanPrinter;

/**
 * Unit tests of the logical optimizer: each rule is applied on its own to the unoptimized
 * logical plan of a query and the result is compared with the expected printed plan.
 */
public final class OptimizerRulesTest {
    private static final Engine ENGINE = engine();

    private OptimizerRulesTest() {
    }

    /** t(id, grp, val, name): 20 rows; u(grp, label): 4 rows; v(id, w): 200 rows with 50 distinct w. */
    private static Engine engine() {
        Engine e = new Engine(new EngineConfig(Path.of(".").toAbsolutePath(), true, 1L << 30, 1L << 30,
                1_000_000, 1_000_000, 1, null));
        StringBuilder t = new StringBuilder("id,grp,val,name\n");
        for (int i = 1; i <= 20; i++) {
            t.append(i).append(',').append(i % 4).append(',').append(i * 3).append(",n").append(i).append('\n');
        }
        e.load(new LoadRequest("t", "csv", null, t.toString(), null, true, ',', false));
        e.load(new LoadRequest("u", "csv", null, "grp,label\n0,a\n1,b\n2,c\n3,d\n", null, true, ',', false));
        StringBuilder v = new StringBuilder("id,w\n");
        for (int i = 1; i <= 200; i++) {
            v.append(i).append(',').append(i % 50).append('\n');
        }
        e.load(new LoadRequest("v", "csv", null, v.toString(), null, true, ',', false));
        return e;
    }

    private static LogicalPlan plan(String sql) {
        return ENGINE.logicalPlan(sql);
    }

    private static void expect(String expected, LogicalPlan actual) {
        String printed = LogicalPlanPrinter.print(actual);
        if (!printed.equals(expected)) {
            throw new AssertionError("expected plan\n" + expected + "but got\n" + printed);
        }
    }

    private static void expect(String expected, OptimizerRule rule, String sql) {
        expect(expected, rule.apply(plan(sql)));
    }

    // ------------------------------------------------------------------ constant folding

    public static void testConstantFoldingEvaluatesLiteralOnlyExpressions() {
        expect("""
                Project [_col1 := (id + 6)]
                  Filter (val > 6)
                    Scan t
                """, new ConstantFolding(), "SELECT id + (2 * 3) FROM t WHERE val > 10 - 4");
    }

    public static void testConstantFoldingLeavesFailingExpressionsForRunTime() {
        expect("""
                Project [id := id]
                  Filter ((id > (1 / 0)) OR (val > 4))
                    Scan t
                """, new ConstantFolding(), "SELECT id FROM t WHERE id > 1 / 0 OR val > 2 + 2");
    }

    // ------------------------------------------------------------------ predicate simplification

    public static void testPredicateSimplificationRemovesConstantOperands() {
        expect("""
                Project [id := id]
                  Filter (id > 3)
                    Scan t
                """, new PredicateSimplification(), "SELECT id FROM t WHERE TRUE AND NOT NOT id > 3 OR FALSE");
    }

    public static void testPredicateSimplificationDropsAlwaysTrueFilters() {
        expect("""
                Project [id := id]
                  Scan t
                """, new PredicateSimplification(), "SELECT id FROM t WHERE id > 3 OR TRUE");
    }

    public static void testPredicateSimplificationKeepsOperandsThatMayFail() {
        // FALSE on the right does not decide: the left operand is evaluated first and may fail
        expect("""
                Project [id := id]
                  Filter (((10 / id) > 1) AND FALSE)
                    Scan t
                """, new PredicateSimplification(), "SELECT id FROM t WHERE 10 / id > 1 AND FALSE");
    }

    // ------------------------------------------------------------------ predicate pushdown

    public static void testPredicatePushdownIntoJoinInputs() {
        expect("""
                Project [id := id]
                  Join INNER ON (grp = grp)
                    Filter (val > 30)
                      Scan t
                    Filter (label = 'b')
                      Scan u
                """, new PredicatePushdown(),
                "SELECT t.id FROM t, u WHERE t.grp = u.grp AND u.label = 'b' AND t.val > 30");
    }

    public static void testPredicatePushdownKeepsNullSupplyingSideOfLeftJoin() {
        expect("""
                Project [id := id]
                  Filter (label = 'b')
                    Join LEFT ON (grp = grp)
                      Filter (id > 2)
                        Scan t
                      Scan u
                """, new PredicatePushdown(),
                "SELECT t.id FROM t LEFT JOIN u ON u.grp = t.grp WHERE u.label = 'b' AND t.id > 2");
    }

    public static void testPredicatePushdownBelowProjection() {
        expect("""
                Project [k := k]
                  Project [k := grp, v := (val + 1), name := name]
                    Filter (grp = 2)
                      Scan t
                """, new PredicatePushdown(),
                "SELECT k FROM (SELECT grp AS k, val + 1 AS v, name FROM t) s WHERE k = 2");
    }

    public static void testPredicatePushdownNotBelowProjectionThatMayFail() {
        // computing q on fewer rows could hide its division by zero
        expect("""
                Project [k := k]
                  Filter (k = 2)
                    Project [k := grp, q := (100 / (grp - 1))]
                      Scan t
                """, new PredicatePushdown(),
                "SELECT k FROM (SELECT grp AS k, 100 / (grp - 1) AS q FROM t) s WHERE k = 2");
    }

    public static void testPredicatePushdownKeepsConjunctsAfterAFailingOne() {
        // (label = 'b') follows a conjunct that may fail: evaluated first it could hide the error
        expect("""
                Project [id := id]
                  Filter (((id / (grp - 1)) > 0) AND (label = 'b'))
                    Join INNER ON (grp = grp)
                      Scan t
                      Scan u
                """, new PredicatePushdown(),
                "SELECT t.id FROM t JOIN u ON u.grp = t.grp WHERE t.id / (u.grp - 1) > 0 AND u.label = 'b'");
    }

    // ------------------------------------------------------------------ join reordering

    public static void testJoinReorderingStartsWithTheSmallestJoin() {
        expect("""
                Project [_col1 := $0]
                  Aggregate keys=[] aggregates=[COUNT(*)]
                    Project [id := id, w := w, id := id, w := w, id := id, grp := grp, val := val, name := name]
                      Join INNER ON (w = w)
                        Join INNER ON (id = id)
                          Scan v AS b
                          Scan t
                        Scan v AS a
                """, new JoinReorder(), "SELECT COUNT(*) FROM v a JOIN v b ON a.w = b.w JOIN t ON t.id = b.id");
    }

    public static void testJoinReorderingLeavesTwoWayJoins() {
        LogicalPlan p = plan("SELECT COUNT(*) FROM v JOIN t ON t.id = v.id");
        expect(LogicalPlanPrinter.print(p), new JoinReorder().apply(p));
    }

    // ------------------------------------------------------------------ projection pruning

    public static void testProjectionPruningReplacesUnreadColumns() {
        expect("""
                Project [k := k]
                  Filter (k = 2)
                    Project [k := grp, v := NULL, name := NULL]
                      Scan t
                """, new ProjectionPruning(), "SELECT k FROM (SELECT grp AS k, val AS v, name FROM t) s WHERE k = 2");
    }

    public static void testProjectionPruningKeepsComputedOutputs() {
        // computing q may fail (division by zero): the query must still raise that error
        expect("""
                Project [k := k]
                  Project [k := grp, q := (100 / (grp - 1)), n := NULL]
                    Scan t
                """, new ProjectionPruning(),
                "SELECT k FROM (SELECT grp AS k, 100 / (grp - 1) AS q, name AS n FROM t) s");
    }

    public static void testProjectionPruningKeepsColumnsReadBySubqueries() {
        expect("""
                Project [k := k]
                  Filter EXISTS(subquery)
                    subquery:
                      Project [_col1 := 1]
                        Filter (grp = outer.g)
                          Scan u
                    Project [k := id, g := grp, n := NULL]
                      Scan t
                """, new ProjectionPruning(), "SELECT k FROM (SELECT id AS k, grp AS g, name AS n FROM t) s "
                + "WHERE EXISTS (SELECT 1 FROM u WHERE u.grp = s.g)");
    }

    // ------------------------------------------------------------------ the optimizer

    public static void testStandardRuleSequence() {
        List<String> names = LogicalOptimizer.STANDARD.rules().stream().map(OptimizerRule::name).toList();
        check(names.equals(List.of("constant_folding", "predicate_simplification", "predicate_pushdown",
                "join_reordering", "projection_pruning")), names.toString());
        expect("""
                Project [k := k]
                  Project [k := grp, v := (val + 1), name := NULL]
                    Filter (grp = 2)
                      Scan t
                """, LogicalOptimizer.STANDARD.optimize(
                plan("SELECT k FROM (SELECT grp AS k, val + 1 AS v, name FROM t) s WHERE k = 1 + 1")));
    }

    public static void testOptimizeFalseAppliesNoRules() {
        LogicalOptimizer disabled = LogicalOptimizer.forOption(false);
        check(disabled.rules().isEmpty(), "rules with optimize: false");
        LogicalPlan p = plan("SELECT t.id FROM t, u WHERE t.grp = u.grp AND 1 = 1");
        check(disabled.optimize(p) == p, "optimize: false changed the plan");
        check(LogicalOptimizer.forOption(true) == LogicalOptimizer.STANDARD, "optimize: true");
    }

    public static void testPrinterShowsSubqueryPlans() {
        expect("""
                Project [id := id]
                  Filter (grp IN (subquery))
                    subquery:
                      Project [grp := grp]
                        Filter (label <> 'a')
                          Scan u
                    Scan t
                """, plan("SELECT id FROM t WHERE grp IN (SELECT grp FROM u WHERE label <> 'a')"));
    }

    private static void check(boolean cond, String msg) {
        if (!cond) {
            throw new AssertionError(msg);
        }
    }
}
