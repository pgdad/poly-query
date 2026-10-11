//! Parallel (multi-threaded) execution of scan pipelines (`threads > 1`,
//! vectorized mode), morsel-driven.
//!
//! A *fragment* is a pipeline that streams rows of one table scan through
//! filters, projections and the probe side of hash / nested-loop joins.
//! The scanned row ranges are cut into morsels; worker threads repeatedly
//! claim the next morsel, instantiate the fragment's operators restricted
//! to it and run them with their own execution context (sharing the
//! query's deadline, cancellation flag and memory budget). Join build
//! sides are executed once, before the workers start, and shared read-only.
//!
//! * [`GatherOp`] returns the morsels' output batches **in scan order**
//!   (identical row order to serial execution), keeping at most a bounded
//!   window of morsels in flight, so `LIMIT` stops the workers early.
//! * [`ParallelAggregateOp`] aggregates each worker's morsels into a
//!   private partial [`Aggregator`] and merges the partials at the end
//!   (also used for DISTINCT: grouping by all columns).

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use super::context::ContextSeed;
use super::vector::agg::Aggregator;
use super::vector::batch::{BATCH_SIZE, Batch};
use super::vector::build::{build, side_keys};
use super::vector::join::{
    HashJoinOp, HashTable, JoinSpec, NestedLoopJoinOp, build_table, materialize,
};
use super::vector::ops::{
    BatchOperator, BoxedBatchOp, FilterOp, ProjectOp, ScanOp, ScanRange, aggregate_batch,
    full_ranges,
};
use crate::error::{Error, Result};
use crate::exec::ExecContext;
use crate::exec::native_filter::{NativeFilter, NativeFilterScanOp};
use crate::native::Kernels;
use crate::planner::expr::{AggregateCall, Expr, KeyDomain};
use crate::planner::logical::JoinType;
use crate::planner::physical::PhysicalPlan;
use crate::protocol::catch_panic;
use crate::storage::Table;

/// Stack size of parallel worker threads (expression evaluation recurses
/// over the expression tree, whose depth the parser bounds).
pub const PARALLEL_STACK_BYTES: usize = 64 * 1024 * 1024;

/// Default rows per morsel.
const DEFAULT_MORSEL_ROWS: usize = 8 * BATCH_SIZE;

/// Default rows per morsel (`POLYQUERY_MORSEL_ROWS` overrides it; used by
/// tests to exercise the parallel operators on small tables).
pub fn default_morsel_rows() -> usize {
    std::env::var("POLYQUERY_MORSEL_ROWS")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|&n| n > 0)
        .unwrap_or(DEFAULT_MORSEL_ROWS)
}

/// A pipeline ending in a table scan, with shared join build sides.
enum Frag {
    Scan {
        table: Arc<Table>,
        columns: Vec<usize>,
    },
    Filter {
        input: Box<Frag>,
        predicate: Expr,
    },
    /// Scan + filter evaluated with the native kernels.
    NativeFilterScan {
        table: Arc<Table>,
        columns: Vec<usize>,
        filter: Arc<NativeFilter>,
        kernels: &'static Kernels,
    },
    Project {
        input: Box<Frag>,
        exprs: Vec<Expr>,
    },
    HashProbe {
        probe: Box<Frag>,
        table: Arc<HashTable>,
        probe_keys: Vec<(Expr, KeyDomain)>,
        spec: JoinSpec,
    },
    NestedLoop {
        left: Box<Frag>,
        right: Arc<Batch>,
        spec: JoinSpec,
    },
}

/// The scan at the bottom of a fragment-shaped plan (None if `plan` is not
/// a fragment).
fn fragment_scan(plan: &PhysicalPlan) -> Option<(&Arc<Table>, &[usize])> {
    match plan {
        PhysicalPlan::TableScan { table, groups, .. }
        | PhysicalPlan::NativeFilterScan { table, groups, .. } => Some((table, groups)),
        PhysicalPlan::Filter { input, .. } | PhysicalPlan::Project { input, .. } => {
            fragment_scan(input)
        }
        PhysicalPlan::HashJoin {
            left,
            right,
            build_left,
            ..
        } => fragment_scan(if *build_left { right } else { left }),
        PhysicalPlan::NestedLoopJoin { left, .. } => fragment_scan(left),
        _ => None,
    }
}

impl Frag {
    /// Prepares a fragment: executes join build sides (with `ctx`).
    fn prepare(plan: PhysicalPlan, ctx: &ExecContext) -> Result<Frag> {
        Ok(match plan {
            PhysicalPlan::TableScan { table, columns, .. } => Frag::Scan { table, columns },
            PhysicalPlan::NativeFilterScan {
                table,
                columns,
                filter,
                kernels,
                ..
            } => Frag::NativeFilterScan {
                table,
                columns,
                filter,
                kernels,
            },
            PhysicalPlan::Filter { input, predicate } => Frag::Filter {
                input: Box::new(Frag::prepare(*input, ctx)?),
                predicate,
            },
            PhysicalPlan::Project { input, exprs, .. } => Frag::Project {
                input: Box::new(Frag::prepare(*input, ctx)?),
                exprs,
            },
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
                let mut build_op = build(*build_side, ctx);
                let table = build_table(&mut *build_op, bw, &side_keys(&keys, build_left), ctx)?;
                Frag::HashProbe {
                    probe: Box::new(Frag::prepare(*probe, ctx)?),
                    table: Arc::new(table),
                    probe_keys: side_keys(&keys, !build_left),
                    spec: JoinSpec {
                        left_join: join_type == JoinType::Left,
                        outer_is_left: !build_left,
                        residual,
                        outer_width: pw,
                        inner_width: bw,
                    },
                }
            }
            PhysicalPlan::NestedLoopJoin {
                left,
                right,
                join_type,
                predicate,
                ..
            } => {
                let (lw, rw) = (left.schema().len(), right.schema().len());
                let mut right_op = build(*right, ctx);
                let right = materialize(&mut *right_op, rw, ctx)?;
                Frag::NestedLoop {
                    left: Box::new(Frag::prepare(*left, ctx)?),
                    right: Arc::new(right),
                    spec: JoinSpec {
                        left_join: join_type == JoinType::Left,
                        outer_is_left: true,
                        residual: predicate,
                        outer_width: lw,
                        inner_width: rw,
                    },
                }
            }
            _ => return Err(Error::internal("not a parallel fragment")),
        })
    }

    /// Operators running this fragment over the scan `ranges`.
    fn instantiate(&self, ranges: &[ScanRange]) -> BoxedBatchOp {
        match self {
            Frag::Scan { table, columns } => {
                Box::new(ScanOp::new(table.clone(), columns.clone(), ranges.to_vec()))
            }
            Frag::NativeFilterScan {
                table,
                columns,
                filter,
                kernels,
            } => Box::new(NativeFilterScanOp::new(
                table.clone(),
                columns.clone(),
                ranges.to_vec(),
                filter.clone(),
                kernels,
            )),
            Frag::Filter { input, predicate } => Box::new(FilterOp {
                input: input.instantiate(ranges),
                predicate: predicate.clone(),
            }),
            Frag::Project { input, exprs } => Box::new(ProjectOp {
                input: input.instantiate(ranges),
                exprs: exprs.clone(),
            }),
            Frag::HashProbe {
                probe,
                table,
                probe_keys,
                spec,
            } => Box::new(HashJoinOp::new(
                probe.instantiate(ranges),
                None,
                Some(table.clone()),
                Vec::new(),
                probe_keys.clone(),
                spec.clone(),
            )),
            Frag::NestedLoop { left, right, spec } => Box::new(NestedLoopJoinOp {
                left: left.instantiate(ranges),
                right_input: None,
                right: Some(right.clone()),
                spec: spec.clone(),
                current: None,
                cursor: Default::default(),
            }),
        }
    }
}

/// Splits the row groups `groups` of `table` into morsels of about
/// `morsel` rows.
fn morsels(table: &Table, groups: &[usize], morsel: usize) -> Vec<Vec<ScanRange>> {
    let mut out = Vec::new();
    for r in full_ranges(table, groups) {
        let mut from = r.from;
        while from < r.to {
            let to = (from + morsel).min(r.to);
            out.push(vec![ScanRange {
                group: r.group,
                from,
                to,
            }]);
            from = to;
        }
    }
    out
}

/// Returns a parallel operator for `plan` if it is worth parallelizing.
pub fn try_build(plan: &PhysicalPlan, ctx: &ExecContext) -> Option<BoxedBatchOp> {
    let threads = ctx.execution.threads;
    if threads <= 1 || ctx.serial_only() {
        return None;
    }
    let morsel = ctx.morsel_rows.max(1);
    let split = |fragment: &PhysicalPlan| {
        let (table, groups) = fragment_scan(fragment)?;
        let m = morsels(table, groups, morsel);
        (m.len() > 1).then_some(m)
    };
    match plan {
        PhysicalPlan::HashAggregate {
            input,
            group_by,
            aggregates,
            ..
        } => {
            let morsels = split(input)?;
            Some(Box::new(ParallelAggregateOp {
                plan: Some((**input).clone()),
                group_by: group_by.clone(),
                aggregates: aggregates.clone(),
                morsels,
                threads,
                seed: ctx.seed(),
                morsel_rows: morsel,
            }))
        }
        // DISTINCT = grouping by every column, without aggregates.
        PhysicalPlan::Distinct { input } => {
            let morsels = split(input)?;
            let group_by = input
                .schema()
                .iter()
                .enumerate()
                .map(|(index, f)| Expr::Column {
                    index,
                    ty: f.data_type,
                })
                .collect();
            Some(Box::new(ParallelAggregateOp {
                plan: Some((**input).clone()),
                group_by,
                aggregates: Vec::new(),
                morsels,
                threads,
                seed: ctx.seed(),
                morsel_rows: morsel,
            }))
        }
        _ => {
            let morsels = split(plan)?;
            Some(Box::new(GatherOp {
                plan: Some(plan.clone()),
                morsels,
                threads,
                seed: ctx.seed(),
                state: None,
            }))
        }
    }
}

fn spawn<T: Send + 'static>(
    name: &str,
    f: impl FnOnce() -> T + Send + 'static,
) -> Result<JoinHandle<T>> {
    std::thread::Builder::new()
        .name(name.to_string())
        .stack_size(PARALLEL_STACK_BYTES)
        .spawn(f)
        .map_err(|e| Error::internal(format!("cannot start worker thread: {e}")))
}

/// Shared state of a gather: morsel results in scan order.
struct GatherShared {
    frag: Frag,
    morsels: Vec<Vec<ScanRange>>,
    seed: ContextSeed,
    next: AtomicUsize,
    stop: Arc<AtomicBool>,
    /// Morsels allowed to be claimed ahead of the consumer.
    window: usize,
    slots: Mutex<GatherSlots>,
    changed: Condvar,
}

struct GatherSlots {
    results: Vec<Option<Result<Vec<Batch>>>>,
    /// Morsels consumed so far.
    consumed: usize,
    /// A worker failed (its error is in `results`).
    failed: bool,
}

impl GatherShared {
    fn work(&self) {
        let ctx = self.seed.worker_context(self.stop.clone());
        loop {
            if self.stop.load(Ordering::Relaxed) {
                return;
            }
            let m = self.next.fetch_add(1, Ordering::Relaxed);
            if m >= self.morsels.len() {
                return;
            }
            {
                let mut slots = self.slots.lock().unwrap_or_else(|e| e.into_inner());
                while m >= slots.consumed + self.window && !self.stop.load(Ordering::Relaxed) {
                    slots = self.changed.wait(slots).unwrap_or_else(|e| e.into_inner());
                }
            }
            if self.stop.load(Ordering::Relaxed) {
                return;
            }
            let result = catch_panic(|| {
                let mut op = self.frag.instantiate(&self.morsels[m]);
                let mut out = Vec::new();
                while let Some(b) = op.next_batch(&ctx)? {
                    out.push(b);
                }
                Ok(out)
            });
            let failed = result.is_err();
            let mut slots = self.slots.lock().unwrap_or_else(|e| e.into_inner());
            slots.results[m] = Some(result);
            slots.failed |= failed;
            drop(slots);
            self.changed.notify_all();
            if failed {
                return;
            }
        }
    }
}

struct GatherState {
    shared: Arc<GatherShared>,
    workers: Vec<JoinHandle<()>>,
    next: usize,
    pending: VecDeque<Batch>,
}

/// Ordered parallel execution of a fragment.
pub struct GatherOp {
    plan: Option<PhysicalPlan>,
    morsels: Vec<Vec<ScanRange>>,
    threads: usize,
    seed: ContextSeed,
    state: Option<GatherState>,
}

impl GatherOp {
    fn start(&mut self, ctx: &ExecContext) -> Result<()> {
        let Some(plan) = self.plan.take() else {
            return Ok(());
        };
        let frag = Frag::prepare(plan, ctx)?;
        let morsels = std::mem::take(&mut self.morsels);
        let workers = self.threads.min(morsels.len());
        let shared = Arc::new(GatherShared {
            frag,
            slots: Mutex::new(GatherSlots {
                results: (0..morsels.len()).map(|_| None).collect(),
                consumed: 0,
                failed: false,
            }),
            morsels,
            seed: self.seed.clone(),
            next: AtomicUsize::new(0),
            stop: Arc::new(AtomicBool::new(false)),
            window: 2 * workers.max(1),
            changed: Condvar::new(),
        });
        let mut handles = Vec::with_capacity(workers);
        for i in 0..workers {
            let s = shared.clone();
            handles.push(spawn(&format!("pq-gather-{i}"), move || s.work())?);
        }
        self.state = Some(GatherState {
            shared,
            workers: handles,
            next: 0,
            pending: VecDeque::new(),
        });
        Ok(())
    }
}

impl BatchOperator for GatherOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        if self.plan.is_some() {
            self.start(ctx)?;
        }
        let Some(state) = &mut self.state else {
            return Ok(None);
        };
        loop {
            if let Some(b) = state.pending.pop_front() {
                return Ok(Some(b));
            }
            let shared = &state.shared;
            if state.next >= shared.morsels.len() {
                return Ok(None);
            }
            let result = {
                let mut slots = shared.slots.lock().unwrap_or_else(|e| e.into_inner());
                loop {
                    if let Some(r) = slots.results[state.next].take() {
                        break r;
                    }
                    if slots.failed {
                        // Report the first failure without waiting for
                        // earlier morsels.
                        if let Some(Some(Err(e))) = slots
                            .results
                            .iter_mut()
                            .find(|r| matches!(r, Some(Err(_))))
                            .map(Option::take)
                        {
                            return Err(e);
                        }
                    }
                    drop(slots);
                    ctx.check_interrupt()?;
                    slots = shared.slots.lock().unwrap_or_else(|e| e.into_inner());
                    if slots.results[state.next].is_none() && !slots.failed {
                        slots = shared
                            .changed
                            .wait_timeout(slots, Duration::from_millis(5))
                            .unwrap_or_else(|e| e.into_inner())
                            .0;
                    }
                }
            };
            state.next += 1;
            {
                let mut slots = shared.slots.lock().unwrap_or_else(|e| e.into_inner());
                slots.consumed = state.next;
            }
            shared.changed.notify_all();
            state.pending.extend(result?);
        }
    }
}

impl Drop for GatherOp {
    fn drop(&mut self) {
        if let Some(state) = self.state.take() {
            {
                // Set under the lock: a worker checking the window condition
                // either sees the flag or is already waiting for the notify.
                let _slots = state.shared.slots.lock().unwrap_or_else(|e| e.into_inner());
                state.shared.stop.store(true, Ordering::Relaxed);
            }
            state.shared.changed.notify_all();
            for h in state.workers {
                let _ = h.join();
            }
        }
    }
}

/// Parallel hash aggregation: per-worker partial aggregates, merged.
pub struct ParallelAggregateOp {
    plan: Option<PhysicalPlan>,
    group_by: Vec<Expr>,
    aggregates: Vec<AggregateCall>,
    morsels: Vec<Vec<ScanRange>>,
    threads: usize,
    seed: ContextSeed,
    /// Merge partials in parallel from this many groups on.
    morsel_rows: usize,
}

struct AggShared {
    frag: Frag,
    morsels: Vec<Vec<ScanRange>>,
    group_by: Vec<Expr>,
    aggregates: Vec<AggregateCall>,
    seed: ContextSeed,
    next: AtomicUsize,
    stop: AtomicBool,
}

impl AggShared {
    fn work(&self) -> Result<Aggregator> {
        let ctx = self.seed.context();
        let mut agg = Aggregator::new(self.group_by.len(), &self.aggregates, ctx.execution.native);
        loop {
            if self.stop.load(Ordering::Relaxed) {
                return Ok(agg);
            }
            let m = self.next.fetch_add(1, Ordering::Relaxed);
            if m >= self.morsels.len() {
                return Ok(agg);
            }
            let r = catch_panic(|| {
                let mut op = self.frag.instantiate(&self.morsels[m]);
                while let Some(b) = op.next_batch(&ctx)? {
                    aggregate_batch(&mut agg, &self.group_by, &self.aggregates, &b, &ctx)?;
                }
                Ok(())
            });
            if let Err(e) = r {
                self.stop.store(true, Ordering::Relaxed);
                return Err(e);
            }
        }
    }
}

impl BatchOperator for ParallelAggregateOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        let Some(plan) = self.plan.take() else {
            return Ok(None);
        };
        let frag = Frag::prepare(plan, ctx)?;
        let morsels = std::mem::take(&mut self.morsels);
        let workers = self.threads.min(morsels.len()).max(1);
        let shared = Arc::new(AggShared {
            frag,
            morsels,
            group_by: self.group_by.clone(),
            aggregates: self.aggregates.clone(),
            seed: self.seed.clone(),
            next: AtomicUsize::new(0),
            stop: AtomicBool::new(false),
        });
        let mut handles = Vec::with_capacity(workers);
        for i in 0..workers {
            let s = shared.clone();
            match spawn(&format!("pq-agg-{i}"), move || s.work()) {
                Ok(h) => handles.push(h),
                Err(e) => {
                    shared.stop.store(true, Ordering::Relaxed);
                    for h in handles {
                        let _ = h.join();
                    }
                    return Err(e);
                }
            }
        }
        let mut partials = Vec::with_capacity(workers);
        let mut first_err = None;
        for h in handles {
            match h.join() {
                Ok(Ok(a)) => partials.push(a),
                Ok(Err(e)) => {
                    first_err.get_or_insert(e);
                }
                Err(_) => {
                    first_err.get_or_insert(Error::internal("aggregation worker panicked"));
                }
            }
        }
        if let Some(e) = first_err {
            return Err(e);
        }
        ctx.check_interrupt()?;
        let total: usize = partials.iter().map(Aggregator::groups).sum();
        // Merging is worth parallelizing once there are about as many
        // groups as rows in a morsel.
        let out = if partials.len() > 1 && total >= self.morsel_rows {
            merge_partitioned(partials, &self.seed, ctx)?
        } else {
            let mut iter = partials.into_iter();
            let mut agg = iter.next().unwrap_or_else(|| {
                Aggregator::new(self.group_by.len(), &self.aggregates, ctx.execution.native)
            });
            for p in iter {
                let retained = agg.merge(p)?;
                if retained > 0 {
                    ctx.reserve(retained)?;
                }
            }
            agg.finish(ctx)?
        };
        Ok((out.len > 0).then_some(out))
    }
}

/// Merges partial aggregators in parallel: each worker's groups are split
/// into hash partitions; partition `p` of every partial is merged (and
/// finished) by thread `p`. Equal keys always meet in the same partition.
fn merge_partitioned(
    partials: Vec<Aggregator>,
    seed: &ContextSeed,
    ctx: &ExecContext,
) -> Result<Batch> {
    let parts = partials.len();
    let key_count = partials[0].key_count();
    let calls = partials[0].calls().to_vec();
    let split: Vec<Vec<Vec<u32>>> = std::thread::scope(|scope| {
        let handles: Vec<_> = partials
            .iter()
            .map(|p| scope.spawn(move || p.partition_groups(parts)))
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().unwrap_or_else(|e| std::panic::resume_unwind(e)))
            .collect()
    });
    let results: Vec<Result<Batch>> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..parts)
            .map(|p| {
                let (partials, split, calls) = (&partials, &split, &calls);
                std::thread::Builder::new()
                    .stack_size(PARALLEL_STACK_BYTES)
                    .spawn_scoped(scope, move || {
                        catch_panic(|| {
                            let wctx = seed.context();
                            let mut agg = Aggregator::new(key_count, calls, wctx.execution.native);
                            for (w, partial) in partials.iter().enumerate() {
                                if let Some(groups) = split[w].get(p) {
                                    let retained = agg.merge_groups(partial, groups)?;
                                    wctx.reserve(retained)?;
                                }
                            }
                            agg.finish(&wctx)
                        })
                    })
            })
            .collect();
        handles
            .into_iter()
            .map(|h| match h {
                Ok(h) => h
                    .join()
                    .unwrap_or_else(|_| Err(Error::internal("aggregation merge panicked"))),
                Err(e) => Err(Error::internal(format!("cannot start worker thread: {e}"))),
            })
            .collect()
    });
    let mut batches = Vec::with_capacity(parts);
    for r in results {
        let b = r?;
        if b.len > 0 {
            batches.push(b);
        }
    }
    ctx.check_interrupt()?;
    let width = key_count + calls.len();
    if batches.is_empty() {
        return Ok(Batch::new(Vec::new(), 0));
    }
    Ok(Batch::concat(batches, width))
}
