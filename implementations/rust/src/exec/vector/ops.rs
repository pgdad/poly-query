//! Batch (vectorized) physical operators.

use std::cmp::Ordering;
use std::sync::Arc;

use super::agg::Aggregator;
use super::batch::{BATCH_SIZE, Batch, Data, Vector};
use super::eval::{eval, eval_mask};
use super::keys::KeyTable;
use crate::error::Result;
use crate::exec::operators::{Operator, Row};
use crate::exec::ExecContext;
use crate::planner::access::IndexLookup;
use crate::planner::expr::{AggregateCall, Expr};
use crate::planner::logical::SortKey;
use crate::storage::{Index, Table};
use crate::types::Value;

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
pub fn read_batch(table: &Table, columns: &[usize], rg: usize, from: usize, to: usize) -> Result<Batch> {
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
        let mut agg = Aggregator::new(self.group_by.len(), &self.aggregates);
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
            let keys = self.keys.get_or_insert_with(|| KeyTable::new(b.width()));
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

/// Comparison form of one sort key over a materialized batch.
enum SortCol {
    I64(Vec<i64>),
    F64(Vec<f64>),
    Str(Vec<Arc<str>>),
    Values(Vec<Value>),
}

struct SortColumn {
    col: SortCol,
    nulls: Option<Vec<bool>>,
    descending: bool,
    nulls_first: bool,
}

impl SortColumn {
    fn new(v: Vector, key: &SortKey) -> SortColumn {
        let nulls = v.validity().map(|valid| valid.into_iter().map(|ok| !ok).collect());
        let col = match v.data {
            Data::Int(x) | Data::Timestamp(x) | Data::Decimal(x, _) => SortCol::I64(x),
            Data::Date(x) => SortCol::I64(x.into_iter().map(i64::from).collect()),
            Data::Bool(x) => SortCol::I64(x.into_iter().map(i64::from).collect()),
            Data::Float(x) => SortCol::F64(x),
            Data::Str(x) => SortCol::Str(x),
            Data::Dict(codes, dict) => {
                // Rank dictionary entries once; equal strings share a rank.
                let mut order: Vec<u32> = (0..dict.len() as u32).collect();
                order.sort_by(|&a, &b| dict[a as usize].as_bytes().cmp(dict[b as usize].as_bytes()));
                let mut rank = vec![0i64; dict.len()];
                let mut r = 0;
                for (k, &e) in order.iter().enumerate() {
                    if k > 0 && dict[e as usize] != dict[order[k - 1] as usize] {
                        r += 1;
                    }
                    rank[e as usize] = r;
                }
                SortCol::I64(codes.into_iter().map(|c| rank[c as usize]).collect())
            }
            Data::Null => SortCol::I64(vec![0; v.len()]),
            Data::Values(x) => SortCol::Values(x),
        };
        SortColumn {
            col,
            nulls,
            descending: key.descending,
            nulls_first: key.nulls_first,
        }
    }

    #[inline]
    fn compare(&self, a: usize, b: usize) -> Ordering {
        if let Some(nulls) = &self.nulls {
            match (nulls[a], nulls[b]) {
                (true, true) => return Ordering::Equal,
                (true, false) => {
                    return if self.nulls_first { Ordering::Less } else { Ordering::Greater };
                }
                (false, true) => {
                    return if self.nulls_first { Ordering::Greater } else { Ordering::Less };
                }
                _ => {}
            }
        }
        let o = match &self.col {
            SortCol::I64(v) => v[a].cmp(&v[b]),
            SortCol::F64(v) => v[a].partial_cmp(&v[b]).unwrap_or(Ordering::Equal),
            SortCol::Str(v) => v[a].as_bytes().cmp(v[b].as_bytes()),
            SortCol::Values(v) => match (v[a].is_null(), v[b].is_null()) {
                (true, true) => Ordering::Equal,
                (true, false) => {
                    return if self.nulls_first { Ordering::Less } else { Ordering::Greater };
                }
                (false, true) => {
                    return if self.nulls_first { Ordering::Greater } else { Ordering::Less };
                }
                _ => v[a].sort_cmp(&v[b]),
            },
        };
        if self.descending { o.reverse() } else { o }
    }
}

fn compare_rows(cols: &[SortColumn], a: usize, b: usize) -> Ordering {
    for c in cols {
        let o = c.compare(a, b);
        if o != Ordering::Equal {
            return o;
        }
    }
    Ordering::Equal
}

/// Compares rows of key vectors with one direction / NULL placement
/// (merge-join keys).
pub struct KeyComparator {
    cols: Vec<SortColumn>,
}

impl KeyComparator {
    pub fn new(vectors: Vec<Vector>, key: &SortKey) -> KeyComparator {
        KeyComparator {
            cols: vectors.into_iter().map(|v| SortColumn::new(v, key)).collect(),
        }
    }

    pub fn compare(&self, a: usize, b: usize) -> Ordering {
        compare_rows(&self.cols, a, b)
    }
}

/// The permutation that sorts `b` by `keys` (stable). With `top`, only the
/// first `top` positions of the stable order.
pub fn sort_permutation(
    b: &Batch,
    keys: &[SortKey],
    top: Option<usize>,
    ctx: &ExecContext,
) -> Result<Vec<u32>> {
    let mut cols = Vec::with_capacity(keys.len());
    for k in keys {
        cols.push(SortColumn::new(eval(&k.expr, b, ctx)?, k));
    }
    let mut idx: Vec<u32> = (0..b.len as u32).collect();
    // Ties are broken by input position, so selection + sort equals the
    // prefix of a stable sort.
    let cmp = |x: &u32, y: &u32| compare_rows(&cols, *x as usize, *y as usize).then(x.cmp(y));
    if let Some(n) = top
        && n < idx.len()
    {
        if n == 0 {
            return Ok(Vec::new());
        }
        idx.select_nth_unstable_by(n - 1, cmp);
        idx.truncate(n);
    }
    ctx.check_interrupt()?;
    idx.sort_unstable_by(cmp);
    Ok(idx)
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
            let take = self.remaining.map_or(n - from as u64, |r| r.min(n - from as u64));
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
}
