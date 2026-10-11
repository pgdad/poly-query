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
