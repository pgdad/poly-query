//! Rule `predicate_pushdown`: moves filter conjuncts and join conditions as
//! close to the scans as possible — below projections (pass-through columns
//! of derived tables and CTEs), into the inputs of joins where that is
//! valid for the join type, and into every branch of a `UNION ALL`. A cross
//! join that receives a condition over both inputs becomes an inner join.

use super::Rule;
use crate::planner::expr::Expr;
use crate::planner::logical::{JoinType, LogicalPlan};

pub struct PredicatePushdown;

impl Rule for PredicatePushdown {
    fn name(&self) -> &'static str {
        "predicate_pushdown"
    }

    fn apply(&self, plan: LogicalPlan) -> LogicalPlan {
        push_down(plan)
    }
}

fn conjuncts(e: Expr) -> Vec<Expr> {
    let mut out = Vec::new();
    e.into_conjuncts(&mut out);
    out
}

/// Pushes filters and join conditions as close to the scans as possible.
fn push_down(plan: LogicalPlan) -> LogicalPlan {
    crate::interrupt::checkpoint();
    match plan {
        LogicalPlan::Filter { input, predicate } => {
            let input = push_down(*input);
            push_conjuncts(input, conjuncts(predicate))
        }
        LogicalPlan::Join {
            left,
            right,
            join_type,
            on,
            ..
        } => {
            let left = push_down(*left);
            let right = push_down(*right);
            let lw = left.width();
            let mut to_right = Vec::new();
            let mut to_left = Vec::new();
            let mut keep = Vec::new();
            for c in on.map(conjuncts).unwrap_or_default() {
                let cols = c.columns();
                let only_left = cols.iter().all(|&i| i < lw);
                let only_right = !cols.is_empty() && cols.iter().all(|&i| i >= lw);
                match join_type {
                    // ON conditions of an inner join are filters on its inputs.
                    JoinType::Inner | JoinType::Cross if only_left && !cols.is_empty() => {
                        to_left.push(c)
                    }
                    // For LEFT JOIN, right-only conditions restrict the
                    // candidate matches; left-only ones must stay.
                    _ if only_right => to_right.push(shift(c, lw)),
                    _ => keep.push(c),
                }
            }
            let left = push_conjuncts(left, to_left);
            let right = push_conjuncts(right, to_right);
            LogicalPlan::join(left, right, join_type, Expr::conjunction(keep))
        }
        LogicalPlan::SingleRow | LogicalPlan::Scan { .. } => plan,
        LogicalPlan::Project {
            input,
            exprs,
            schema,
        } => LogicalPlan::Project {
            input: Box::new(push_down(*input)),
            exprs,
            schema,
        },
        LogicalPlan::Aggregate {
            input,
            group_by,
            aggregates,
            schema,
        } => LogicalPlan::Aggregate {
            input: Box::new(push_down(*input)),
            group_by,
            aggregates,
            schema,
        },
        LogicalPlan::Distinct { input } => LogicalPlan::Distinct {
            input: Box::new(push_down(*input)),
        },
        LogicalPlan::Sort { input, keys } => LogicalPlan::Sort {
            input: Box::new(push_down(*input)),
            keys,
        },
        LogicalPlan::Limit {
            input,
            offset,
            limit,
        } => LogicalPlan::Limit {
            input: Box::new(push_down(*input)),
            offset,
            limit,
        },
        LogicalPlan::UnionAll { inputs, schema } => LogicalPlan::UnionAll {
            inputs: inputs.into_iter().map(push_down).collect(),
            schema,
        },
    }
}

/// Rebases column references of a right-side-only expression.
fn shift(mut e: Expr, by: usize) -> Expr {
    e.remap_columns(&|i| i - by);
    e
}

/// Places `preds` (conjuncts over `plan`'s output) as deep as possible.
fn push_conjuncts(plan: LogicalPlan, preds: Vec<Expr>) -> LogicalPlan {
    if preds.is_empty() {
        return plan;
    }
    crate::interrupt::checkpoint();
    match plan {
        LogicalPlan::Filter { input, predicate } => {
            let mut all = conjuncts(predicate);
            all.extend(preds);
            push_conjuncts(*input, all)
        }
        LogicalPlan::Join {
            left,
            right,
            join_type,
            on,
            ..
        } => {
            let lw = left.width();
            let (mut to_left, mut to_right, mut to_on, mut above) =
                (Vec::new(), Vec::new(), Vec::new(), Vec::new());
            for p in preds {
                let cols = p.columns();
                let only_left = cols.iter().all(|&i| i < lw);
                let only_right = !cols.is_empty() && cols.iter().all(|&i| i >= lw);
                if only_left {
                    // Filtering left rows before the join is valid for INNER,
                    // CROSS and LEFT joins alike.
                    to_left.push(p);
                } else if join_type == JoinType::Left {
                    above.push(p);
                } else if only_right {
                    to_right.push(shift(p, lw));
                } else {
                    to_on.push(p);
                }
            }
            let left = push_conjuncts(*left, to_left);
            let right = push_conjuncts(*right, to_right);
            let (join_type, on) = if to_on.is_empty() {
                (join_type, on)
            } else {
                let mut all = on.map(conjuncts).unwrap_or_default();
                all.extend(to_on);
                (JoinType::Inner, Expr::conjunction(all))
            };
            let join = LogicalPlan::join(left, right, join_type, on);
            LogicalPlan::filter(join, Expr::conjunction(above))
        }
        // Through a projection (derived table, CTE): conjuncts that only read
        // pass-through columns are rewritten onto the projection's input.
        LogicalPlan::Project {
            input,
            exprs,
            schema,
        } => {
            let source = |i: usize| match &exprs[i] {
                Expr::Column { index, .. } => Some(*index),
                _ => None,
            };
            let (mut below, mut above) = (Vec::new(), Vec::new());
            for mut p in preds {
                if p.columns().into_iter().all(|i| source(i).is_some()) {
                    p.remap_columns(&|i| source(i).unwrap_or(i));
                    below.push(p);
                } else {
                    above.push(p);
                }
            }
            let project = LogicalPlan::Project {
                input: Box::new(push_conjuncts(*input, below)),
                exprs,
                schema,
            };
            LogicalPlan::filter(project, Expr::conjunction(above))
        }
        // A filter over a concatenation filters every branch (the branches
        // produce the union's columns in order).
        LogicalPlan::UnionAll { inputs, schema } => LogicalPlan::UnionAll {
            inputs: inputs
                .into_iter()
                .map(|input| push_conjuncts(input, preds.clone()))
                .collect(),
            schema,
        },
        other => LogicalPlan::filter(other, Expr::conjunction(preds)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::planner::expr::ArithKind;
    use crate::planner::optimizer::test_util::*;
    use crate::sql::ast::BinaryOp::{self, Eq, Gt, Lt};
    use crate::types::DataType;

    fn tables() -> (LogicalPlan, LogicalPlan) {
        let t = table("t", &["a", "b"], 12);
        let u = table("u", &["c", "d"], 8);
        (scan(&t), scan(&u))
    }

    #[test]
    fn splits_a_filter_over_an_inner_join_into_its_inputs() {
        let (t, u) = tables();
        // WHERE t.a > 2 AND u.d < 20 AND t.a = u.c over a cross join.
        let pred = and(
            and(cmp(Gt, col(0), int(2)), cmp(Lt, col(3), int(10))),
            cmp(Eq, col(0), col(2)),
        );
        let plan = filter(join(t, u, JoinType::Cross, None), pred);
        let plan = apply_checked(&PredicatePushdown, plan);
        assert_eq!(
            show(&plan),
            "Join INNER ON (#0 = #2)\n\
             \x20 Filter (#0 > 2)\n\
             \x20   Scan t [a, b]\n\
             \x20 Filter (#1 < 10)\n\
             \x20   Scan u [c, d]"
        );
    }

    #[test]
    fn keeps_right_side_where_conjuncts_above_a_left_join() {
        let (t, u) = tables();
        let on = cmp(Eq, col(0), col(2));
        let pred = and(cmp(Gt, col(1), int(3)), cmp(Lt, col(3), int(10)));
        let plan = filter(join(t, u, JoinType::Left, Some(on)), pred);
        let plan = apply_checked(&PredicatePushdown, plan);
        assert_eq!(
            show(&plan),
            "Filter (#3 < 10)\n\
             \x20 Join LEFT ON (#0 = #2)\n\
             \x20   Filter (#1 > 3)\n\
             \x20     Scan t [a, b]\n\
             \x20   Scan u [c, d]"
        );
    }

    #[test]
    fn pushes_right_only_on_conditions_of_a_left_join_into_the_right_input() {
        let (t, u) = tables();
        let on = and(
            and(cmp(Eq, col(0), col(2)), cmp(Lt, col(3), int(10))),
            cmp(Gt, col(1), int(3)),
        );
        let plan = join(t, u, JoinType::Left, Some(on));
        let plan = apply_checked(&PredicatePushdown, plan);
        // The left-only condition must stay: it does not remove left rows.
        assert_eq!(
            show(&plan),
            "Join LEFT ON ((#0 = #2) AND (#1 > 3))\n\
             \x20 Scan t [a, b]\n\
             \x20 Filter (#1 < 10)\n\
             \x20   Scan u [c, d]"
        );
    }

    #[test]
    fn pushes_through_pass_through_columns_of_a_projection() {
        let (t, _) = tables();
        // SELECT * FROM (SELECT b, a + 1 AS a1 FROM t) WHERE b > 3 AND a1 > 5
        let a_plus_1 = Expr::Arith {
            op: BinaryOp::Add,
            kind: ArithKind::Int,
            left: Box::new(col(0)),
            right: Box::new(int(1)),
            ty: DataType::Int64,
        };
        let mut derived = project(t, &[1, 0]);
        if let LogicalPlan::Project { exprs, .. } = &mut derived {
            exprs[1] = a_plus_1;
        }
        let plan = filter(
            derived,
            and(cmp(Gt, col(0), int(3)), cmp(Gt, col(1), int(5))),
        );
        let plan = apply_checked(&PredicatePushdown, plan);
        assert_eq!(
            show(&plan),
            "Filter (#1 > 5)\n\
             \x20 Project [b := #1, a := (#0 + 1)]\n\
             \x20   Filter (#1 > 3)\n\
             \x20     Scan t [a, b]"
        );
    }

    #[test]
    fn filters_every_branch_of_a_union() {
        let (t, u) = tables();
        let schema = t.schema().to_vec();
        let plan = filter(
            LogicalPlan::UnionAll {
                inputs: vec![t, u],
                schema,
            },
            cmp(Gt, col(1), int(4)),
        );
        let plan = apply_checked(&PredicatePushdown, plan);
        assert_eq!(
            show(&plan),
            "UnionAll [a, b]\n\
             \x20 Filter (#1 > 4)\n\
             \x20   Scan t [a, b]\n\
             \x20 Filter (#1 > 4)\n\
             \x20   Scan u [c, d]"
        );
    }
}
