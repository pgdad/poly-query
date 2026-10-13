"""The planning pipeline of a statement: bound query → logical plan
(``planner.py``) → rule-based optimizer (``optimizer.py``) → physical plan
(``physical.py``)."""

from __future__ import annotations

from ..analysis import bound as b
from .optimizer import Optimizer
from .physical import PhysicalPlan, PhysicalPlanner, PlanOptions
from .planner import LogicalPlanner


def plan_statement(statement: b.BoundStatement, options: PlanOptions) -> PhysicalPlan:
    logical = LogicalPlanner(statement.ids).plan_statement(statement.query)
    options.check()
    optimized = Optimizer.for_options(options.optimize, options.evaluate, options.check).optimize(logical)
    options.check()
    return PhysicalPlanner(options).plan_statement(optimized)
