//! Logical optimization (indexes-and-planning.md §3): constant folding and
//! predicate simplification ([`super::rewrite`]), predicate pushdown, join
//! reordering ([`super::reorder`]) and column pruning. All rewrites
//! preserve results.

use super::expr::Expr;
use super::logical::{JoinType, LogicalPlan};
use super::{reorder, rewrite};

/// Optimizes a logical plan. With `rewrites` (query option `optimize`,
/// default true) the logical rewrites run; column pruning (projection
/// pushdown) is always applied, since scans must read only referenced
/// columns.
pub fn optimize(plan: LogicalPlan, rewrites: bool) -> LogicalPlan {
    let plan = if rewrites {
        let plan = rewrite::simplify_plan(plan);
        let plan = push_down(plan);
        reorder::reorder_joins(plan)
    } else {
        plan
    };
    let width = plan.width();
    let (plan, _) = prune(plan, &(0..width).collect::<Vec<_>>());
    plan
}

// ------------------------------------------------------------ predicate pushdown

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

// ------------------------------------------------------------ column pruning

/// Marker for a column that was pruned away.
const DROPPED: usize = usize::MAX;

fn remap(e: &mut Expr, map: &[usize]) {
    e.remap_columns(&|i| {
        let j = map[i];
        debug_assert_ne!(j, DROPPED, "reference to a pruned column");
        j
    });
}

/// `plan` restricted to its output columns `columns` (in that order),
/// projecting only if that is not already its exact output.
fn select_columns(plan: LogicalPlan, columns: &[usize]) -> LogicalPlan {
    if columns.iter().copied().eq(0..plan.width()) {
        return plan;
    }
    let schema: Vec<_> = columns.iter().map(|&i| plan.schema()[i].clone()).collect();
    let exprs = columns
        .iter()
        .zip(&schema)
        .map(|(&index, f)| Expr::Column {
            index,
            ty: f.data_type,
        })
        .collect();
    LogicalPlan::Project {
        input: Box::new(plan),
        exprs,
        schema,
    }
}

fn union(required: &[usize], extra: impl IntoIterator<Item = usize>) -> Vec<usize> {
    let mut v: Vec<usize> = required.iter().copied().chain(extra).collect();
    v.sort_unstable();
    v.dedup();
    v
}

/// Removes columns not needed by the parent. `required` is the sorted set of
/// output columns the parent reads; the result maps each old output column
/// index to its new index (`DROPPED` if removed). Columns outside `required`
/// may survive (e.g. those a filter needs).
fn prune(plan: LogicalPlan, required: &[usize]) -> (LogicalPlan, Vec<usize>) {
    match plan {
        LogicalPlan::SingleRow => (LogicalPlan::SingleRow, Vec::new()),
        LogicalPlan::Scan {
            table,
            columns,
            schema,
            indexes,
        } => {
            let mut map = vec![DROPPED; columns.len()];
            for (new, &old) in required.iter().enumerate() {
                map[old] = new;
            }
            let plan = LogicalPlan::Scan {
                table,
                columns: required.iter().map(|&i| columns[i]).collect(),
                schema: required.iter().map(|&i| schema[i].clone()).collect(),
                indexes,
            };
            (plan, map)
        }
        LogicalPlan::Filter {
            input,
            mut predicate,
        } => {
            let need = union(required, predicate.columns());
            let (input, map) = prune(*input, &need);
            remap(&mut predicate, &map);
            (
                LogicalPlan::Filter {
                    input: Box::new(input),
                    predicate,
                },
                map,
            )
        }
        LogicalPlan::Project {
            input,
            exprs,
            schema,
        } => {
            let mut map = vec![DROPPED; exprs.len()];
            let mut kept = Vec::with_capacity(required.len());
            let mut kept_schema = Vec::with_capacity(required.len());
            for (new, &old) in required.iter().enumerate() {
                map[old] = new;
                kept.push(exprs[old].clone());
                kept_schema.push(schema[old].clone());
            }
            let need = union(&[], kept.iter().flat_map(|e| e.columns()));
            let (input, input_map) = prune(*input, &need);
            for e in &mut kept {
                remap(e, &input_map);
            }
            let plan = LogicalPlan::Project {
                input: Box::new(input),
                exprs: kept,
                schema: kept_schema,
            };
            (plan, map)
        }
        LogicalPlan::Aggregate {
            input,
            mut group_by,
            mut aggregates,
            schema,
        } => {
            let need = union(
                &[],
                group_by
                    .iter()
                    .chain(aggregates.iter().filter_map(|a| a.arg.as_ref()))
                    .flat_map(|e| e.columns()),
            );
            let (input, map) = prune(*input, &need);
            for e in group_by
                .iter_mut()
                .chain(aggregates.iter_mut().filter_map(|a| a.arg.as_mut()))
            {
                remap(e, &map);
            }
            let identity = (0..schema.len()).collect();
            let plan = LogicalPlan::Aggregate {
                input: Box::new(input),
                group_by,
                aggregates,
                schema,
            };
            (plan, identity)
        }
        LogicalPlan::Join {
            left,
            right,
            join_type,
            mut on,
            ..
        } => {
            let lw = left.width();
            let need = union(required, on.iter().flat_map(|e| e.columns()));
            let left_need: Vec<usize> = need.iter().copied().filter(|&i| i < lw).collect();
            let right_need: Vec<usize> = need
                .iter()
                .copied()
                .filter(|&i| i >= lw)
                .map(|i| i - lw)
                .collect();
            let (left, lmap) = prune(*left, &left_need);
            let (right, rmap) = prune(*right, &right_need);
            let new_lw = left.width();
            let map: Vec<usize> = lmap
                .into_iter()
                .chain(
                    rmap.into_iter()
                        .map(|j| if j == DROPPED { DROPPED } else { j + new_lw }),
                )
                .collect();
            if let Some(on) = &mut on {
                remap(on, &map);
            }
            (LogicalPlan::join(left, right, join_type, on), map)
        }
        LogicalPlan::Distinct { input } => {
            let all: Vec<usize> = (0..input.width()).collect();
            let (input, map) = prune(*input, &all);
            (
                LogicalPlan::Distinct {
                    input: Box::new(input),
                },
                map,
            )
        }
        LogicalPlan::Sort { input, mut keys } => {
            let need = union(required, keys.iter().flat_map(|k| k.expr.columns()));
            let (input, map) = prune(*input, &need);
            for k in &mut keys {
                remap(&mut k.expr, &map);
            }
            (
                LogicalPlan::Sort {
                    input: Box::new(input),
                    keys,
                },
                map,
            )
        }
        LogicalPlan::Limit {
            input,
            offset,
            limit,
        } => {
            let (input, map) = prune(*input, required);
            (
                LogicalPlan::Limit {
                    input: Box::new(input),
                    offset,
                    limit,
                },
                map,
            )
        }
        // Every branch is pruned to exactly the required columns, so that
        // all branches keep producing the same layout.
        LogicalPlan::UnionAll { inputs, schema } => {
            let inputs = inputs
                .into_iter()
                .map(|input| {
                    let (input, map) = prune(input, required);
                    let columns: Vec<usize> = required.iter().map(|&i| map[i]).collect();
                    select_columns(input, &columns)
                })
                .collect();
            let mut map = vec![DROPPED; schema.len()];
            for (new, &old) in required.iter().enumerate() {
                map[old] = new;
            }
            let schema = required.iter().map(|&i| schema[i].clone()).collect();
            (LogicalPlan::UnionAll { inputs, schema }, map)
        }
    }
}
