//! Rule `column_pruning` (projection pushdown): every operator keeps only
//! the columns its consumers read, so scans read only referenced columns and
//! projections drop unused expressions. The plan's output columns are
//! unchanged.

use super::Rule;
use crate::planner::expr::Expr;
use crate::planner::logical::LogicalPlan;

pub struct ColumnPruning;

impl Rule for ColumnPruning {
    fn name(&self) -> &'static str {
        "column_pruning"
    }

    fn apply(&self, plan: LogicalPlan) -> LogicalPlan {
        prune_columns(plan)
    }
}

/// `plan` with every column its output does not depend on removed.
pub fn prune_columns(plan: LogicalPlan) -> LogicalPlan {
    let width = plan.width();
    let (plan, _) = prune(plan, &(0..width).collect::<Vec<_>>());
    plan
}

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
    crate::interrupt::checkpoint();
    match plan {
        LogicalPlan::SingleRow => (LogicalPlan::SingleRow, Vec::new()),
        LogicalPlan::Scan {
            table,
            columns,
            schema,
        } => {
            let mut map = vec![DROPPED; columns.len()];
            for (new, &old) in required.iter().enumerate() {
                map[old] = new;
            }
            let plan = LogicalPlan::Scan {
                table,
                columns: required.iter().map(|&i| columns[i]).collect(),
                schema: required.iter().map(|&i| schema[i].clone()).collect(),
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::planner::logical::JoinType;
    use crate::planner::optimizer::test_util::*;
    use crate::sql::ast::BinaryOp::{Eq, Gt};

    #[test]
    fn scans_read_only_referenced_columns() {
        let t = table("t", &["a", "b", "c"], 6);
        // SELECT c FROM t WHERE a > 2
        let plan = project(filter(scan(&t), cmp(Gt, col(0), int(2))), &[2]);
        let plan = apply_checked(&ColumnPruning, plan);
        assert_eq!(
            show(&plan),
            "Project [c := #1]\n\
             \x20 Filter (#0 > 2)\n\
             \x20   Scan t [a, c]"
        );
    }

    #[test]
    fn prunes_both_join_inputs_and_remaps_the_condition() {
        let t = table("t", &["a", "b", "c"], 6);
        let u = table("u", &["d", "e"], 4);
        // SELECT u.e FROM t JOIN u ON t.c = u.d
        let joined = join(
            scan(&t),
            scan(&u),
            JoinType::Inner,
            Some(cmp(Eq, col(2), col(3))),
        );
        let plan = apply_checked(&ColumnPruning, project(joined, &[4]));
        assert_eq!(
            show(&plan),
            "Project [e := #2]\n\
             \x20 Join INNER ON (#0 = #1)\n\
             \x20   Scan t [c]\n\
             \x20   Scan u [d, e]"
        );
    }

    #[test]
    fn drops_unused_expressions_of_inner_projections() {
        let t = table("t", &["a", "b", "c"], 6);
        // SELECT b FROM (SELECT a, b, c FROM t)
        let plan = project(project(scan(&t), &[0, 1, 2]), &[1]);
        let plan = apply_checked(&ColumnPruning, plan);
        assert_eq!(
            show(&plan),
            "Project [b := #0]\n\
             \x20 Project [b := #0]\n\
             \x20   Scan t [b]"
        );
    }

    #[test]
    fn keeps_every_column_below_distinct() {
        let t = table("t", &["a", "b"], 6);
        let plan = LogicalPlan::Distinct {
            input: Box::new(scan(&t)),
        };
        let plan = apply_checked(&ColumnPruning, plan);
        assert_eq!(show(&plan), "Distinct\n  Scan t [a, b]");
    }

    #[test]
    fn is_idempotent() {
        // Physical planning prunes plans again (for `optimize: false`), so
        // pruning a pruned plan must not change it.
        let t = table("t", &["a", "b", "c"], 6);
        let u = table("u", &["d", "e"], 4);
        let plan = project(
            filter(
                join(scan(&t), scan(&u), JoinType::Cross, None),
                cmp(Eq, col(1), col(3)),
            ),
            &[4, 0],
        );
        let once = prune_columns(plan);
        assert_eq!(show(&prune_columns(once.clone())), show(&once));
    }
}
