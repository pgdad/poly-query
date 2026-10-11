//! Common subplans: an aggregation that occurs more than once in a
//! statement with exactly the same plan — typically a CTE referenced twice,
//! e.g. once in the main query and once in a scalar subquery — is computed
//! once per query execution. Every occurrence is wrapped in
//! [`PhysicalPlan::Shared`] with a common id; at run time the first one to
//! execute materializes its rows and the others replay them.
//!
//! Only parameter-free subtrees made of scans, filters, projections and
//! aggregations are shared (no subqueries, no correlation parameters), and
//! only between the main plan and uncorrelated subquery plans, so a shared
//! result is the same wherever it is used.

use std::sync::Arc;

use super::expr::Expr;
use super::physical::{PhysicalPlan, SubqueryPlans};

/// Wraps the aggregations occurring several times in `root` and the
/// uncorrelated subquery plans in `Shared` nodes.
pub fn share_common_subplans(root: &mut PhysicalPlan, subqueries: &mut SubqueryPlans) {
    let mut found = Vec::new();
    collect(root, &mut found);
    for sub in subqueries.values().filter(|s| !s.row_at_a_time) {
        collect(&sub.plan, &mut found);
    }
    // Representatives of the subtrees occurring at least twice.
    let mut shared: Vec<PhysicalPlan> = Vec::new();
    for (i, plan) in found.iter().enumerate() {
        let repeated = found[i + 1..].iter().any(|other| same_plan(plan, other));
        if repeated && !shared.iter().any(|s| same_plan(s, plan)) {
            shared.push(plan.clone());
        }
    }
    if shared.is_empty() {
        return;
    }
    wrap(root, &shared);
    for sub in subqueries.values_mut().filter(|s| !s.row_at_a_time) {
        wrap(&mut sub.plan, &shared);
    }
}

/// The shareable aggregations of `plan` (also nested ones), outermost
/// first.
fn collect(plan: &PhysicalPlan, out: &mut Vec<PhysicalPlan>) {
    if matches!(plan, PhysicalPlan::HashAggregate { .. }) && shareable(plan) {
        out.push(plan.clone());
    }
    for child in plan.children() {
        collect(child, out);
    }
}

/// Replaces the subtrees equal to `shared[id]` by `Shared` nodes.
fn wrap(plan: &mut PhysicalPlan, shared: &[PhysicalPlan]) {
    if let Some(id) = shared.iter().position(|s| same_plan(s, plan)) {
        let input = std::mem::replace(plan, PhysicalPlan::Values);
        *plan = PhysicalPlan::Shared {
            id,
            input: Box::new(input),
        };
        return;
    }
    for child in plan.children_mut() {
        wrap(child, shared);
    }
}

/// Whether `plan` consists of shareable operators over parameter-free
/// expressions.
fn shareable(plan: &PhysicalPlan) -> bool {
    let plain = |e: &Expr| {
        !e.any(&|x| {
            matches!(
                x,
                Expr::Param { .. }
                    | Expr::ScalarSubquery { .. }
                    | Expr::Exists { .. }
                    | Expr::InSubquery { .. }
            )
        })
    };
    match plan {
        PhysicalPlan::TableScan { .. } => true,
        PhysicalPlan::Filter { input, predicate } => plain(predicate) && shareable(input),
        PhysicalPlan::Project { input, exprs, .. } => exprs.iter().all(plain) && shareable(input),
        PhysicalPlan::HashAggregate {
            input,
            group_by,
            aggregates,
            ..
        } => {
            group_by.iter().all(plain)
                && aggregates.iter().all(|a| a.arg.as_ref().is_none_or(plain))
                && shareable(input)
        }
        _ => false,
    }
}

/// Structural equality of shareable plans (same table snapshot, columns,
/// row groups and expressions).
fn same_plan(a: &PhysicalPlan, b: &PhysicalPlan) -> bool {
    match (a, b) {
        (
            PhysicalPlan::TableScan {
                table: ta,
                columns: ca,
                groups: ga,
                ..
            },
            PhysicalPlan::TableScan {
                table: tb,
                columns: cb,
                groups: gb,
                ..
            },
        ) => Arc::ptr_eq(ta, tb) && ca == cb && ga == gb,
        (
            PhysicalPlan::Filter {
                input: ia,
                predicate: pa,
            },
            PhysicalPlan::Filter {
                input: ib,
                predicate: pb,
            },
        ) => pa == pb && same_plan(ia, ib),
        (
            PhysicalPlan::Project {
                input: ia,
                exprs: ea,
                ..
            },
            PhysicalPlan::Project {
                input: ib,
                exprs: eb,
                ..
            },
        ) => ea == eb && same_plan(ia, ib),
        (
            PhysicalPlan::HashAggregate {
                input: ia,
                group_by: ga,
                aggregates: aa,
                ..
            },
            PhysicalPlan::HashAggregate {
                input: ib,
                group_by: gb,
                aggregates: ab,
                ..
            },
        ) => ga == gb && aa == ab && same_plan(ia, ib),
        _ => false,
    }
}
