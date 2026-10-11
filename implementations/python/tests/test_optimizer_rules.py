"""Unit tests for the logical plan and each rule of the logical optimizer
(``polyquery/planner/rules``), applied on their own and through the
``Optimizer``."""

import unittest

from polyquery.analysis import bound as b
from polyquery.analysis.binder import Binder
from polyquery.datatypes import BOOLEAN, INT64
from polyquery.execution.compiler import evaluate_constant
from polyquery.planner import logical as lp
from polyquery.planner.optimizer import Optimizer, default_rules
from polyquery.planner.planner import LogicalPlanner
from polyquery.planner.rules import (
    ColumnPruning,
    ConstantFolding,
    PredicatePushdown,
    PredicateSimplification,
    RewriteExpressions,
)
from polyquery.sql.parser import parse
from tests.helpers import EngineTestMixin

PEOPLE = "id,name,age,city\n1,Ann,34,Oulu\n2,Bob,,Espoo\n3,Cid,28,Oulu\n"
ORDERS = "oid,pid,amount\n10,1,5.50\n11,1,7.25\n12,3,1.00\n13,,2.00\n"

TRUE, FALSE = b.Literal(BOOLEAN, True), b.Literal(BOOLEAN, False)
X = b.ColumnRef(BOOLEAN, 1, 0, "x")
Y = b.ColumnRef(INT64, 1, 1, "y")


def lit(value: int) -> b.Literal:
    return b.Literal(INT64, value)


def risky() -> b.Expr:
    """``1 / y = 1``: may raise division by zero."""
    return b.Compare(BOOLEAN, "=", b.Arith(INT64, "/", lit(1), Y), lit(1))


class LogicalPlanCase(EngineTestMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.load_csv("people", PEOPLE)
        self.load_csv("orders", ORDERS)

    def logical(self, sql: str) -> lp.LogicalPlan:
        binder = Binder(self.handler.engine.catalog, evaluate_constant)
        stmt = binder.bind_statement(parse(sql).query)
        return LogicalPlanner(stmt.ids).plan_statement(stmt.query)

    def apply(self, rules, sql: str) -> str:
        """The root tree of ``sql`` after ``rules``, as text."""
        return lp.format_plan(Optimizer(rules).optimize(self.logical(sql)).root)

    def assertPlan(self, actual: str, *lines: str):
        self.assertEqual(actual, "\n".join(lines))


class LogicalPlanTests(LogicalPlanCase):
    def test_plan_lists_the_relational_operators(self):
        plan = self.logical(
            "SELECT city, COUNT(*) AS n FROM people p JOIN orders o ON o.pid = p.id "
            "WHERE age > 20 GROUP BY city ORDER BY n DESC LIMIT 2"
        )
        self.assertPlan(
            lp.format_plan(plan.root),
            "Limit limit 2",
            "  Sort #2 DESC",
            "    Project city, COUNT",
            "      Aggregate keys [city] aggregates [COUNT(*)]",
            "        Filter (age > 20)",
            "          Join INNER ON (pid = id)",
            "            Scan people AS p [id, age, city]",
            "            Scan orders AS o [pid]",
        )
        self.assertEqual([c.name for c in plan.columns], ["city", "n"])

    def test_subqueries_get_their_own_trees(self):
        plan = self.logical(
            "SELECT name FROM people p WHERE EXISTS (SELECT 1 FROM orders o WHERE o.pid = p.id "
            "AND o.amount > (SELECT MIN(amount) FROM orders))"
        )
        self.assertEqual(len(plan.subqueries), 2)  # nested subqueries are collected too
        self.assertIn("subquery", str(plan))
        derived = self.logical("SELECT x FROM (SELECT id AS x FROM people) d")
        self.assertEqual(derived.subqueries, {})
        self.assertTrue(any(isinstance(n, lp.SubqueryScan) for n in lp.walk(derived.root)))


class ConstantFoldingTests(LogicalPlanCase):
    def test_folds_constant_subexpressions(self):
        rule = ConstantFolding(evaluate_constant)
        self.assertEqual(rule.rewrite(b.Arith(INT64, "+", lit(1), lit(2))), lit(3))
        column = b.Arith(INT64, "+", Y, lit(2))
        self.assertIs(rule.rewrite(column), column)

    def test_leaves_failing_and_side_effecting_expressions(self):
        rule = ConstantFolding(evaluate_constant)
        failing = b.Arith(INT64, "/", lit(1), lit(0))
        self.assertIs(rule.rewrite(failing), failing)  # the error is raised if a row evaluates it
        sleep = b.Function(INT64, "PQ_SLEEP", (lit(0),))
        self.assertIs(rule.rewrite(sleep), sleep)

    def test_rule_on_a_plan(self):
        self.assertPlan(
            self.apply([ConstantFolding(evaluate_constant)], "SELECT id * (2 + 3) FROM people WHERE age > 10 * 3"),
            "Project (id * 5)",
            "  Filter (age > 30)",
            "    Scan people [id, age]",
        )
        # a predicate folded to TRUE disappears
        self.assertPlan(
            self.apply([ConstantFolding(evaluate_constant)], "SELECT id FROM people WHERE 1 = 1"),
            "Project id",
            "  Scan people [id]",
        )


class PredicateSimplificationTests(LogicalPlanCase):
    def test_boolean_identities(self):
        rule = PredicateSimplification()
        self.assertEqual(rule.rewrite(b.Logical(BOOLEAN, "AND", TRUE, X)), X)
        self.assertEqual(rule.rewrite(b.Logical(BOOLEAN, "OR", FALSE, X)), X)
        self.assertEqual(rule.rewrite(b.Logical(BOOLEAN, "AND", X, FALSE)), FALSE)
        self.assertEqual(rule.rewrite(b.Not(BOOLEAN, b.Not(BOOLEAN, X))), X)
        null_cmp = b.Compare(BOOLEAN, "=", Y, b.Literal(INT64, None))
        self.assertEqual(rule.rewrite(null_cmp), b.Literal(BOOLEAN, None))

    def test_keeps_operands_that_may_fail(self):
        rule = PredicateSimplification()
        kept = b.Logical(BOOLEAN, "AND", risky(), FALSE)
        self.assertEqual(rule.rewrite(kept), kept)  # the left operand is evaluated first
        self.assertEqual(rule.rewrite(b.Logical(BOOLEAN, "OR", TRUE, risky())), TRUE)

    def test_case_with_constant_conditions(self):
        rule = PredicateSimplification()
        case = b.Case(INT64, ((FALSE, lit(1)), (X, lit(2))), lit(3))
        self.assertEqual(rule.rewrite(case), b.Case(INT64, ((X, lit(2)),), lit(3)))
        self.assertEqual(rule.rewrite(b.Case(INT64, ((TRUE, lit(1)), (X, lit(2))), None)), lit(1))
        self.assertEqual(rule.rewrite(b.Case(INT64, ((FALSE, lit(1)),), None)), b.Literal(INT64, None))

    def test_rule_on_a_plan(self):
        self.assertPlan(
            self.apply([PredicateSimplification()], "SELECT id FROM people WHERE TRUE AND age > 1 AND age > 1"),
            "Project id",
            "  Filter (age > 1)",
            "    Scan people [id, age]",
        )
        self.assertPlan(
            self.apply([PredicateSimplification()], "SELECT p.id FROM people p JOIN orders o ON TRUE OR p.id = o.pid"),
            "Project id",
            "  Join CROSS",
            "    Scan people AS p [id]",
            "    Scan orders AS o [pid]",
        )

    def test_runs_in_one_pass_with_constant_folding(self):
        # simplification yields NOT FALSE, which folding turns into TRUE
        rules = [ConstantFolding(evaluate_constant), PredicateSimplification()]
        self.assertPlan(
            self.apply(rules, "SELECT id FROM people WHERE NOT (FALSE AND age > 3)"),
            "Project id",
            "  Scan people [id, age]",  # no ColumnPruning in this sequence
        )
        fused = RewriteExpressions(rules)
        expr = b.Not(BOOLEAN, b.Logical(BOOLEAN, "AND", FALSE, X))
        self.assertEqual(fused.rewrite(expr), TRUE)


class PredicatePushdownTests(LogicalPlanCase):
    def test_moves_conjuncts_into_join_inputs(self):
        self.assertPlan(
            self.apply(
                [PredicatePushdown()],
                "SELECT p.name FROM people p, orders o WHERE o.pid = p.id AND p.age > 30 AND o.amount > 2",
            ),
            "Project name",
            "  Join INNER ON (pid = id)",
            "    Filter (age > 30)",
            "      Scan people AS p [id, name, age]",
            "    Filter (amount > 2)",
            "      Scan orders AS o [pid, amount]",
        )

    def test_left_join_keeps_conditions_on_the_nullable_side(self):
        self.assertPlan(
            self.apply(
                [PredicatePushdown()],
                "SELECT p.id FROM people p LEFT JOIN orders o ON o.pid = p.id AND o.amount > 2 "
                "WHERE o.oid IS NULL AND p.age > 1",
            ),
            "Project id",
            "  Filter (oid IS NULL)",
            "    Join LEFT ON (pid = id)",
            "      Filter (age > 1)",
            "        Scan people AS p [id, age]",
            "      Filter (amount > 2)",
            "        Scan orders AS o [oid, pid, amount]",
        )

    def test_moves_conjuncts_below_derived_table_projections(self):
        self.assertPlan(
            self.apply(
                [PredicatePushdown()],
                "SELECT n FROM (SELECT name AS n, age AS a FROM people WHERE id > 0) d WHERE a > 30",
            ),
            "Project n",
            "  SubqueryScan d",
            "    Project name, age",
            "      Filter ((id > 0) AND (age > 30))",
            "        Scan people [id, name, age]",
        )

    def test_keeps_conjuncts_above_projections_that_may_fail(self):
        # moving the filter below would skip the division for filtered rows
        self.assertPlan(
            self.apply([PredicatePushdown()], "SELECT n FROM (SELECT name AS n, 10 / age AS r FROM people) d WHERE n = 'Ann'"),
            "Project n",
            "  Filter (n = 'Ann')",
            "    SubqueryScan d",
            "      Project name, (10 / age)",
            "        Scan people [name, age]",
        )
        # a conjunct that may fail stays where it was, too
        self.assertPlan(
            self.apply([PredicatePushdown()], "SELECT a FROM (SELECT age AS a FROM people) d WHERE 10 / a > 1"),
            "Project a",
            "  Filter ((10 / a) > 1)",
            "    SubqueryScan d",
            "      Project age",
            "        Scan people [age]",
        )

    def test_stops_at_limits(self):
        self.assertPlan(
            self.apply([PredicatePushdown()], "SELECT a FROM (SELECT age AS a FROM people LIMIT 2) d WHERE a > 1"),
            "Project a",
            "  Filter (a > 1)",
            "    SubqueryScan d",
            "      Limit limit 2",
            "        Project age",
            "          Scan people [age]",
        )


class ColumnPruningTests(LogicalPlanCase):
    def test_scans_read_only_referenced_columns(self):
        plan = self.logical("SELECT COUNT(*) FROM people WHERE age > 1")
        scan = next(n for n in lp.walk(plan.root) if isinstance(n, lp.Scan))
        self.assertEqual(scan.columns, [2])  # the binder records age only
        self.assertPlan(
            self.apply([ColumnPruning()], "SELECT w.name FROM (SELECT * FROM people) w"),
            "Project name",
            "  SubqueryScan w",
            "    Project NULL, name, NULL, NULL",
            "      Scan people [name]",
        )

    def test_keeps_derived_outputs_that_may_fail(self):
        self.assertPlan(
            self.apply([ColumnPruning()], "SELECT w.name FROM (SELECT name, 1 / id AS r FROM people) w"),
            "Project name",
            "  SubqueryScan w",
            "    Project name, (1 / id)",
            "      Scan people [id, name]",
        )


class OptimizerTests(LogicalPlanCase):
    SQL = (
        "SELECT name FROM (SELECT * FROM people) d WHERE age > 10 + 20 "
        "AND id IN (SELECT pid FROM orders WHERE TRUE AND amount > 1)"
    )

    def test_no_rules_leave_the_plan_unchanged(self):
        before = str(self.logical(self.SQL))
        self.assertEqual(str(Optimizer.for_options(False, evaluate_constant).optimize(self.logical(self.SQL))), before)

    def test_default_rules_apply_to_every_tree(self):
        self.assertEqual(
            [rule.name for rule in default_rules(evaluate_constant)],
            ["constant_folding", "predicate_simplification", "predicate_pushdown", "column_pruning"],
        )
        plan = Optimizer.for_options(True, evaluate_constant).optimize(self.logical(self.SQL))
        self.assertPlan(
            str(plan),
            "Project name",
            "  Filter (id IN (subquery #4))",
            "    SubqueryScan d",
            "      Project id, name, NULL, NULL",
            "        Filter (age > 30)",
            "          Scan people [id, name, age]",
            "subquery 4:",
            "  Project pid",
            "    Filter (amount > 1.0)",
            "      Scan orders [pid, amount]",
        )


if __name__ == "__main__":
    unittest.main()
