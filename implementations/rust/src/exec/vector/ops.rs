//! Batch (vectorized) physical operators.

use std::collections::VecDeque;
use std::sync::Arc;

use super::agg::Aggregator;
use super::batch::{BATCH_SIZE, Batch, Vector};
use super::eval::{eval, eval_mask};
use super::keys::KeyTable;
use super::sort::sort_permutation;
use crate::error::Result;
use crate::exec::ExecContext;
use crate::exec::operators::{Operator, Row};
use crate::planner::access::IndexLookup;
use crate::planner::expr::{AggregateCall, Expr};
use crate::planner::logical::SortKey;
use crate::storage::{Index, Table};
use crate::types::DataType;

/// A pull-based operator producing batches (never empty ones).
pub trait BatchOperator {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>>;
}

pub type BoxedBatchOp = Box<dyn BatchOperator>;

/// One empty row (`SELECT` without `FROM`).
pub struct ValuesOp {
    pub done: bool,
}

impl BatchOperator for ValuesOp {
    fn next_batch(&mut self, _ctx: &ExecContext) -> Result<Option<Batch>> {
        if self.done {
            return Ok(None);
        }
        self.done = true;
        Ok(Some(Batch::new(Vec::new(), 1)))
    }
}

/// A contiguous row range of one row group.
#[derive(Debug, Clone, Copy)]
pub struct ScanRange {
    pub group: usize,
    pub from: usize,
    pub to: usize,
}

/// The ranges covering whole row groups `groups` of `table`.
pub fn full_ranges(table: &Table, groups: &[usize]) -> Vec<ScanRange> {
    groups
        .iter()
        .map(|&g| ScanRange {
            group: g,
            from: 0,
            to: table.row_groups()[g].len,
        })
        .filter(|r| r.to > r.from)
        .collect()
}

/// Reads row ranges of a table as batches of column vectors, copying
/// typed slices straight out of the column chunks.
pub struct ScanOp {
    table: Arc<Table>,
    columns: Vec<usize>,
    ranges: Vec<ScanRange>,
    range: usize,
    pos: usize,
}

impl ScanOp {
    pub fn new(table: Arc<Table>, columns: Vec<usize>, ranges: Vec<ScanRange>) -> ScanOp {
        let pos = ranges.first().map_or(0, |r| r.from);
        ScanOp {
            table,
            columns,
            ranges,
            range: 0,
            pos,
        }
    }
}

/// Rows `[from, to)` of row group `rg`, projected to `columns`.
pub fn read_batch(
    table: &Table,
    columns: &[usize],
    rg: usize,
    from: usize,
    to: usize,
) -> Result<Batch> {
    let n = to - from;
    if let Some(rows) = table.row_slice(rg, from, to) {
        let cols = columns
            .iter()
            .map(|&c| Vector::from_values(rows.iter().map(|r| r[c].clone()).collect()))
            .collect();
        return Ok(Batch::new(cols, n));
    }
    let mut cols = Vec::with_capacity(columns.len());
    for &c in columns {
        match table.column_chunk(rg, c)? {
            Some(chunk) => cols.push(Vector::from_column(chunk, from, to)),
            None => unreachable!("column chunk of a row-layout table"),
        }
    }
    Ok(Batch::new(cols, n))
}

impl BatchOperator for ScanOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        loop {
            let Some(r) = self.ranges.get(self.range).copied() else {
                return Ok(None);
            };
            if self.pos >= r.to {
                self.range += 1;
                if let Some(next) = self.ranges.get(self.range) {
                    self.pos = next.from;
                }
                continue;
            }
            ctx.check_interrupt()?;
            let to = (self.pos + BATCH_SIZE).min(r.to);
            let b = read_batch(&self.table, &self.columns, r.group, self.pos, to)?;
            self.pos = to;
            return Ok(Some(b));
        }
    }
}

/// Rows located through an index lookup, in table order.
pub struct IndexScanOp {
    pub table: Arc<Table>,
    pub index: Arc<Index>,
    pub lookup: IndexLookup,
    pub columns: Vec<usize>,
    pub ids: Option<Vec<u32>>,
    pub pos: usize,
}

impl BatchOperator for IndexScanOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        let ids = self.ids.get_or_insert_with(|| self.lookup.run(&self.index));
        if self.pos >= ids.len() {
            return Ok(None);
        }
        ctx.check_interrupt()?;
        let to = (self.pos + BATCH_SIZE).min(ids.len());
        let rows = self.table.read_rows(&ids[self.pos..to], &self.columns)?;
        self.pos = to;
        Ok(Some(Batch::from_rows(&rows, self.columns.len())))
    }
}

pub struct FilterOp {
    pub input: BoxedBatchOp,
    pub predicate: Expr,
}

impl BatchOperator for FilterOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        while let Some(b) = self.input.next_batch(ctx)? {
            let mask = eval_mask(&self.predicate, &b, ctx)?;
            let kept = mask.iter().filter(|&&m| m).count();
            if kept == b.len {
                return Ok(Some(b));
            }
            if kept > 0 {
                return Ok(Some(b.filter(&mask)));
            }
        }
        Ok(None)
    }
}

pub struct ProjectOp {
    pub input: BoxedBatchOp,
    pub exprs: Vec<Expr>,
}

impl BatchOperator for ProjectOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        let Some(b) = self.input.next_batch(ctx)? else {
            return Ok(None);
        };
        let mut cols = Vec::with_capacity(self.exprs.len());
        for e in &self.exprs {
            cols.push(eval(e, &b, ctx)?);
        }
        Ok(Some(Batch::new(cols, b.len)))
    }
}

/// Evaluates group keys and aggregate arguments of one input batch and
/// adds it to `agg`.
pub fn aggregate_batch(
    agg: &mut Aggregator,
    group_by: &[Expr],
    aggregates: &[AggregateCall],
    b: &Batch,
    ctx: &ExecContext,
) -> Result<()> {
    let mut keys = Vec::with_capacity(group_by.len());
    for e in group_by {
        keys.push(eval(e, b, ctx)?);
    }
    let mut args = Vec::with_capacity(aggregates.len());
    for a in aggregates {
        args.push(match &a.arg {
            Some(e) => Some(eval(e, b, ctx)?),
            None => None,
        });
    }
    let retained = agg.update(&keys, &args, b.len)?;
    if retained > 0 {
        ctx.reserve(retained)?;
    }
    Ok(())
}

/// Hash aggregation (one output batch).
pub struct AggregateOp {
    pub input: Option<BoxedBatchOp>,
    pub group_by: Vec<Expr>,
    pub aggregates: Vec<AggregateCall>,
}

impl BatchOperator for AggregateOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        let Some(mut input) = self.input.take() else {
            return Ok(None);
        };
        let mut agg = Aggregator::new(self.group_by.len(), &self.aggregates, ctx.execution.native);
        while let Some(b) = input.next_batch(ctx)? {
            aggregate_batch(&mut agg, &self.group_by, &self.aggregates, &b, ctx)?;
        }
        let out = agg.finish(ctx)?;
        Ok((out.len > 0).then_some(out))
    }
}

/// Streams the first occurrence of each distinct row.
pub struct DistinctOp {
    pub input: BoxedBatchOp,
    pub keys: Option<KeyTable>,
    pub gids: Vec<u32>,
}

impl BatchOperator for DistinctOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        while let Some(b) = self.input.next_batch(ctx)? {
            let keys = self
                .keys
                .get_or_insert_with(|| KeyTable::with_native(b.width(), ctx.execution.native));
            let mut next = keys.len() as u32;
            let before = next;
            if b.width() == 0 {
                // All rows are equal: only the very first one survives.
                if next > 0 {
                    continue;
                }
                keys.assign(&[], 1, &mut self.gids);
                return Ok(Some(Batch::new(Vec::new(), 1)));
            }
            keys.assign(&b.columns, b.len, &mut self.gids);
            let mask: Vec<bool> = self
                .gids
                .iter()
                .map(|&g| {
                    if g == next {
                        next += 1;
                        true
                    } else {
                        false
                    }
                })
                .collect();
            if next > before {
                let out = b.filter(&mask);
                ctx.reserve(out.approx_size() * 2)?;
                return Ok(Some(out));
            }
        }
        Ok(None)
    }
}

/// Sort / top-N. Input batches are materialized (compacted to the best
/// `top` rows from time to time for top-N), sorted by permutation and
/// emitted in batches.
pub struct SortOp {
    pub input: Option<BoxedBatchOp>,
    pub keys: Vec<SortKey>,
    pub top: Option<usize>,
    pub width: usize,
    pub output: Option<(Batch, usize)>,
}

impl SortOp {
    fn compute(&self, mut input: BoxedBatchOp, ctx: &ExecContext) -> Result<Batch> {
        let mut parts: Vec<Batch> = Vec::new();
        let mut rows = 0usize;
        let mut reserved = 0usize;
        while let Some(b) = input.next_batch(ctx)? {
            let size = b.approx_size();
            ctx.reserve(size)?;
            reserved += size;
            rows += b.len;
            parts.push(b);
            if let Some(n) = self.top
                && rows >= n.saturating_mul(2).max(8 * BATCH_SIZE)
            {
                let all = Batch::concat(&parts, self.width);
                let mut keep = sort_permutation(&all, &self.keys, Some(n), ctx)?;
                keep.sort_unstable();
                let kept = all.gather(&keep);
                ctx.release(reserved);
                reserved = kept.approx_size();
                ctx.reserve(reserved)?;
                rows = kept.len;
                parts = vec![kept];
            }
        }
        if parts.is_empty() {
            return Ok(Batch::new(Vec::new(), 0));
        }
        let all = Batch::concat(&parts, self.width);
        let perm = sort_permutation(&all, &self.keys, self.top, ctx)?;
        Ok(all.gather(&perm))
    }
}

impl BatchOperator for SortOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        if let Some(input) = self.input.take() {
            let sorted = self.compute(input, ctx)?;
            self.output = Some((sorted, 0));
        }
        emit_slices(&mut self.output)
    }
}

/// Emits a materialized batch in slices of `BATCH_SIZE` rows.
pub fn emit_slices(output: &mut Option<(Batch, usize)>) -> Result<Option<Batch>> {
    let Some((b, pos)) = output else {
        return Ok(None);
    };
    if *pos >= b.len {
        *output = None;
        return Ok(None);
    }
    if *pos == 0 && b.len <= BATCH_SIZE {
        let out = output.take().map(|(b, _)| b);
        return Ok(out);
    }
    let to = (*pos + BATCH_SIZE).min(b.len);
    let out = b.slice(*pos, to);
    *pos = to;
    Ok(Some(out))
}

pub struct LimitOp {
    pub input: BoxedBatchOp,
    pub offset: u64,
    pub remaining: Option<u64>,
}

impl BatchOperator for LimitOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        loop {
            if self.remaining == Some(0) {
                return Ok(None);
            }
            let Some(b) = self.input.next_batch(ctx)? else {
                return Ok(None);
            };
            let n = b.len as u64;
            if self.offset >= n {
                self.offset -= n;
                continue;
            }
            let from = self.offset as usize;
            self.offset = 0;
            let take = self
                .remaining
                .map_or(n - from as u64, |r| r.min(n - from as u64));
            if let Some(r) = &mut self.remaining {
                *r -= take;
            }
            let to = from + take as usize;
            return Ok(Some(if from == 0 && to == b.len {
                b
            } else {
                b.slice(from, to)
            }));
        }
    }
}

/// `UNION ALL`: the batches of each input in turn. Exhausted inputs are
/// dropped right away, releasing their state.
pub struct UnionAllOp {
    pub inputs: VecDeque<BoxedBatchOp>,
}

impl BatchOperator for UnionAllOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        while let Some(input) = self.inputs.front_mut() {
            if let Some(b) = input.next_batch(ctx)? {
                return Ok(Some(b));
            }
            self.inputs.pop_front();
        }
        Ok(None)
    }
}

/// Adapts a row operator to the batch interface.
pub struct RowSource {
    pub input: Box<dyn Operator>,
    pub width: usize,
    pub done: bool,
}

impl BatchOperator for RowSource {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        if self.done {
            return Ok(None);
        }
        let mut rows: Vec<Row> = Vec::new();
        while rows.len() < BATCH_SIZE {
            match self.input.next(ctx)? {
                Some(r) => rows.push(r),
                None => {
                    self.done = true;
                    break;
                }
            }
        }
        if rows.is_empty() {
            return Ok(None);
        }
        Ok(Some(Batch::from_rows(&rows, self.width)))
    }
}

/// Adapts a batch operator to the row interface (plan roots, subqueries).
pub struct RowSink {
    pub input: BoxedBatchOp,
    pub rows: std::vec::IntoIter<Row>,
}

impl RowSink {
    pub fn new(input: BoxedBatchOp) -> RowSink {
        RowSink {
            input,
            rows: Vec::new().into_iter(),
        }
    }
}

impl Operator for RowSink {
    fn next(&mut self, ctx: &ExecContext) -> Result<Option<Row>> {
        loop {
            if let Some(r) = self.rows.next() {
                return Ok(Some(r));
            }
            match self.input.next_batch(ctx)? {
                Some(b) => self.rows = b.into_rows().into_iter(),
                None => return Ok(None),
            }
        }
    }

    fn write_json(
        &mut self,
        ctx: &ExecContext,
        out: &mut String,
        types: &[DataType],
        max: u64,
    ) -> Result<u64> {
        if self.rows.len() > 0 {
            // Rows already converted by `next` are written first.
            let mut n = 0;
            while n < max {
                let Some(row) = self.rows.next() else { break };
                if out.len() > 1 {
                    out.push(',');
                }
                crate::protocol::write_row(&row, types, out);
                n += 1;
            }
            return Ok(n);
        }
        let Some(b) = self.input.next_batch(ctx)? else {
            return Ok(0);
        };
        if b.len as u64 > max {
            self.rows = b.into_rows().into_iter();
            return self.write_json(ctx, out, types, max);
        }
        for i in 0..b.len {
            if out.len() > 1 {
                out.push(',');
            }
            out.push('[');
            for (j, c) in b.columns.iter().enumerate() {
                if j > 0 {
                    out.push(',');
                }
                c.write_json(i, types[j], out);
            }
            out.push(']');
        }
        Ok(b.len as u64)
    }

    fn skip(&mut self, ctx: &ExecContext, max: u64) -> Result<u64> {
        let pending = self.rows.len() as u64;
        if pending > 0 {
            let n = pending.min(max);
            self.rows.nth(n as usize - 1);
            return Ok(n);
        }
        // Whole batches are counted without converting them to rows.
        match self.input.next_batch(ctx)? {
            Some(b) if b.len as u64 <= max => Ok(b.len as u64),
            Some(b) => {
                self.rows = b.into_rows().into_iter();
                self.skip(ctx, max)
            }
            None => Ok(0),
        }
    }
}
