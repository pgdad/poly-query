//! Builds batch operator trees from physical plans. With `threads > 1`,
//! scan pipelines are executed by the parallel operators of
//! [`crate::exec::parallel`].

use super::join::{HashJoinOp, JoinSpec, MergeJoinOp, NestedLoopJoinOp};
use super::keys::KeyTable;
use super::ops::{
    AggregateOp, BoxedBatchOp, DistinctOp, FilterOp, IndexScanOp, LimitOp, ProjectOp, RowSource,
    ScanOp, SortOp, UnionAllOp, ValuesOp, full_ranges,
};

use crate::exec::ExecContext;
use crate::exec::native_filter::NativeFilterScanOp;
use crate::exec::operators::build_row;
use crate::exec::parallel;
use crate::planner::expr::{Expr, KeyDomain};
use crate::planner::logical::JoinType;
use crate::planner::physical::{JoinKey, PhysicalPlan};

/// Key expressions of one join side.
pub fn side_keys(keys: &[JoinKey], left: bool) -> Vec<(Expr, KeyDomain)> {
    keys.iter()
        .map(|k| ((if left { &k.left } else { &k.right }).clone(), k.domain))
        .collect()
}

/// Builds the batch operator tree of `plan`.
pub fn build(plan: PhysicalPlan, ctx: &ExecContext) -> BoxedBatchOp {
    build_with(plan, ctx, true)
}

/// Builds `plan`; with `parallel = false` the scan pipeline at the top of
/// `plan` runs serially (its pipeline breakers' inputs may still run in
/// parallel).
fn build_with(plan: PhysicalPlan, ctx: &ExecContext, parallel: bool) -> BoxedBatchOp {
    if parallel && let Some(op) = parallel::try_build(&plan, ctx) {
        return op;
    }
    build_serial(plan, ctx, parallel)
}

fn build_serial(plan: PhysicalPlan, ctx: &ExecContext, parallel: bool) -> BoxedBatchOp {
    match plan {
        PhysicalPlan::Values => Box::new(ValuesOp { done: false }),
        PhysicalPlan::TableScan {
            table,
            columns,
            groups,
            ..
        } => {
            let ranges = full_ranges(&table, &groups);
            Box::new(ScanOp::new(table, columns, ranges))
        }
        PhysicalPlan::IndexScan {
            table,
            index,
            lookup,
            columns,
            ..
        } => Box::new(IndexScanOp {
            table,
            index,
            lookup,
            columns,
            ids: None,
            pos: 0,
        }),
        PhysicalPlan::NativeFilterScan {
            table,
            columns,
            groups,
            filter,
            kernels,
            ..
        } => {
            let ranges = full_ranges(&table, &groups);
            Box::new(NativeFilterScanOp::new(
                table, columns, ranges, filter, kernels,
            ))
        }
        PhysicalPlan::Filter { input, predicate } => Box::new(FilterOp {
            input: build_with(*input, ctx, parallel),
            predicate,
        }),
        PhysicalPlan::Project { input, exprs, .. } => Box::new(ProjectOp {
            input: build_with(*input, ctx, parallel),
            exprs,
        }),
        PhysicalPlan::HashAggregate {
            input,
            group_by,
            aggregates,
            ..
        } => Box::new(AggregateOp {
            input: Some(build(*input, ctx)),
            group_by,
            aggregates,
        }),
        PhysicalPlan::HashJoin {
            left,
            right,
            join_type,
            keys,
            residual,
            build_left,
            ..
        } => {
            let (lw, rw) = (left.schema().len(), right.schema().len());
            let (probe, build_side, pw, bw) = if build_left {
                (right, left, rw, lw)
            } else {
                (left, right, lw, rw)
            };
            let spec = JoinSpec {
                left_join: join_type == JoinType::Left,
                outer_is_left: !build_left,
                residual,
                outer_width: pw,
                inner_width: bw,
            };
            Box::new(HashJoinOp::new(
                build_with(*probe, ctx, parallel),
                Some((build(*build_side, ctx), bw)),
                None,
                side_keys(&keys, build_left),
                side_keys(&keys, !build_left),
                spec,
            ))
        }
        PhysicalPlan::MergeJoin {
            left,
            right,
            join_type,
            keys,
            residual,
            ..
        } => {
            let (lw, rw) = (left.schema().len(), right.schema().len());
            Box::new(MergeJoinOp {
                left: Some((build(*left, ctx), lw)),
                right: Some((build(*right, ctx), rw)),
                left_keys: side_keys(&keys, true),
                right_keys: side_keys(&keys, false),
                spec: JoinSpec {
                    left_join: join_type == JoinType::Left,
                    outer_is_left: true,
                    residual,
                    outer_width: lw,
                    inner_width: rw,
                },
                state: None,
                cursor: Default::default(),
            })
        }
        PhysicalPlan::NestedLoopJoin {
            left,
            right,
            join_type,
            predicate,
            ..
        } => {
            let (lw, rw) = (left.schema().len(), right.schema().len());
            Box::new(NestedLoopJoinOp {
                left: build_with(*left, ctx, parallel),
                right_input: Some((build(*right, ctx), rw)),
                right: None,
                spec: JoinSpec {
                    left_join: join_type == JoinType::Left,
                    outer_is_left: true,
                    residual: predicate,
                    outer_width: lw,
                    inner_width: rw,
                },
                current: None,
                cursor: Default::default(),
            })
        }
        PhysicalPlan::Distinct { input } => Box::new(DistinctOp {
            input: build(*input, ctx),
            keys: None::<KeyTable>,
            gids: Vec::new(),
        }),
        plan @ PhysicalPlan::ParamLookup { .. } => {
            let width = plan.schema().len();
            Box::new(RowSource {
                input: build_row(plan),
                width,
                done: false,
            })
        }
        PhysicalPlan::Sort { input, keys, top } => {
            let width = input.schema().len();
            Box::new(SortOp {
                input: Some(build(*input, ctx)),
                keys,
                top,
                width,
                output: None,
            })
        }
        PhysicalPlan::Limit {
            input,
            offset,
            limit,
        } => {
            // A small LIMIT over a scan pipeline is answered serially: the
            // scan stops after the first batches, whereas parallel workers
            // would read ahead.
            // (A top-N sort reads its whole input either way.)
            let small = !matches!(*input, PhysicalPlan::Sort { .. })
                && limit.is_some_and(|l| offset.saturating_add(l) <= ctx.morsel_rows as u64);
            Box::new(LimitOp {
                input: build_with(*input, ctx, !small),
                offset,
                remaining: limit,
            })
        }
        PhysicalPlan::UnionAll { inputs, .. } => Box::new(UnionAllOp {
            inputs: inputs
                .into_iter()
                .map(|p| build_with(p, ctx, parallel))
                .collect(),
        }),
    }
}
