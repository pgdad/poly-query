//! Cardinality estimation over logical plans, from table statistics and
//! the selectivity model of [`super::access`]. Used by the `join_reorder`
//! rule (join order) and by physical planning (hash-join build side).

use super::access;
use super::logical::{JoinType, LogicalPlan};

/// Rough estimate of the number of rows `plan` produces.
pub fn estimate_rows(plan: &LogicalPlan) -> f64 {
    match plan {
        LogicalPlan::SingleRow => 1.0,
        LogicalPlan::Scan { table, .. } => table.row_count as f64,
        LogicalPlan::Filter { input, predicate } => match &**input {
            LogicalPlan::Scan { table, columns, .. } => {
                let mut conjuncts = Vec::new();
                predicate.clone().into_conjuncts(&mut conjuncts);
                table.row_count as f64 * access::filter_selectivity(table, columns, &conjuncts)
            }
            _ => estimate_rows(input) * access::DEFAULT_SELECTIVITY,
        },
        LogicalPlan::Project { input, .. }
        | LogicalPlan::Sort { input, .. }
        | LogicalPlan::Distinct { input } => estimate_rows(input),
        LogicalPlan::Aggregate {
            input, group_by, ..
        } => {
            if group_by.is_empty() {
                1.0
            } else {
                (estimate_rows(input) / 2.0).max(1.0)
            }
        }
        LogicalPlan::Join {
            left,
            right,
            join_type,
            on,
            ..
        } => {
            let (l, r) = (estimate_rows(left), estimate_rows(right));
            match (join_type, on) {
                (JoinType::Cross, _) | (_, None) => l * r,
                (JoinType::Left, _) => l.max(r),
                _ => l.max(r),
            }
        }
        LogicalPlan::Limit { input, limit, .. } => {
            let n = estimate_rows(input);
            limit.map_or(n, |l| n.min(l as f64))
        }
        LogicalPlan::UnionAll { inputs, .. } => inputs.iter().map(estimate_rows).sum(),
    }
}
