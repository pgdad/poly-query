//! Physical operators (pull-based, row-at-a-time iterator model).

use std::cmp::Ordering;
use std::collections::HashMap;
use std::sync::Arc;

use super::aggregate::AggState;
use super::context::ExecContext;
use super::eval::{eval, eval_predicate};
use crate::error::Result;
use crate::planner::expr::{AggregateCall, Expr};
use crate::planner::logical::{LogicalPlan, SortKey};
use crate::storage::Table;
use crate::types::Value;

pub type Row = Vec<Value>;

/// Rows between interruption checks in tight loops.
const CHECK_INTERVAL: usize = 1024;

pub trait Operator {
    /// Produces the next row, or None when exhausted.
    fn next(&mut self, ctx: &ExecContext) -> Result<Option<Row>>;
}

/// Builds the operator tree for a logical plan.
pub fn build(plan: LogicalPlan) -> Box<dyn Operator> {
    match plan {
        LogicalPlan::SingleRow => Box::new(SingleRowOp { done: false }),
        LogicalPlan::Scan { table, columns, .. } => Box::new(ScanOp {
            table,
            columns,
            pos: 0,
        }),
        LogicalPlan::Filter { input, predicate } => Box::new(FilterOp {
            input: build(*input),
            predicate,
        }),
        LogicalPlan::Project { input, exprs, .. } => Box::new(ProjectOp {
            input: build(*input),
            exprs,
        }),
        LogicalPlan::Aggregate {
            input,
            group_by,
            aggregates,
            ..
        } => Box::new(AggregateOp {
            input: Some(build(*input)),
            group_by,
            aggregates,
            output: Vec::new().into_iter(),
        }),
        LogicalPlan::Sort { input, keys } => Box::new(SortOp::new(build(*input), keys, None)),
        LogicalPlan::Limit {
            input,
            offset,
            limit,
        } => {
            let input = match (*input, limit) {
                // ORDER BY … LIMIT: only the first offset+limit rows are needed.
                (LogicalPlan::Sort { input, keys }, Some(n)) => {
                    let top = usize::try_from(offset.saturating_add(n)).unwrap_or(usize::MAX);
                    Box::new(SortOp::new(build(*input), keys, Some(top)))
                }
                (other, _) => build(other),
            };
            Box::new(LimitOp {
                input,
                offset,
                remaining: limit,
            })
        }
    }
}

struct SingleRowOp {
    done: bool,
}

impl Operator for SingleRowOp {
    fn next(&mut self, _ctx: &ExecContext) -> Result<Option<Row>> {
        if self.done {
            return Ok(None);
        }
        self.done = true;
        Ok(Some(Vec::new()))
    }
}

struct ScanOp {
    table: Arc<Table>,
    columns: Vec<usize>,
    pos: usize,
}

impl Operator for ScanOp {
    fn next(&mut self, ctx: &ExecContext) -> Result<Option<Row>> {
        if self.pos >= self.table.row_count {
            return Ok(None);
        }
        if self.pos.is_multiple_of(CHECK_INTERVAL) {
            ctx.check_interrupt()?;
        }
        let row = self
            .columns
            .iter()
            .map(|&c| self.table.columns[c].value(self.pos))
            .collect();
        self.pos += 1;
        Ok(Some(row))
    }
}

struct FilterOp {
    input: Box<dyn Operator>,
    predicate: Expr,
}

impl Operator for FilterOp {
    fn next(&mut self, ctx: &ExecContext) -> Result<Option<Row>> {
        while let Some(row) = self.input.next(ctx)? {
            if eval_predicate(&self.predicate, &row, ctx)? {
                return Ok(Some(row));
            }
        }
        Ok(None)
    }
}

struct ProjectOp {
    input: Box<dyn Operator>,
    exprs: Vec<Expr>,
}

impl Operator for ProjectOp {
    fn next(&mut self, ctx: &ExecContext) -> Result<Option<Row>> {
        let Some(row) = self.input.next(ctx)? else {
            return Ok(None);
        };
        let mut out = Vec::with_capacity(self.exprs.len());
        for e in &self.exprs {
            out.push(eval(e, &row, ctx)?);
        }
        Ok(Some(out))
    }
}

/// Hash aggregation; without GROUP BY there is exactly one group, even for
/// empty input.
struct AggregateOp {
    input: Option<Box<dyn Operator>>,
    group_by: Vec<Expr>,
    aggregates: Vec<AggregateCall>,
    output: std::vec::IntoIter<Row>,
}

impl AggregateOp {
    fn compute(&mut self, mut input: Box<dyn Operator>, ctx: &ExecContext) -> Result<Vec<Row>> {
        let new_states =
            |aggs: &[AggregateCall]| aggs.iter().map(AggState::new).collect::<Vec<_>>();
        let mut groups: Vec<(Row, Vec<AggState>)> = Vec::new();
        let mut index: HashMap<Row, usize> = HashMap::new();
        if self.group_by.is_empty() {
            groups.push((Vec::new(), new_states(&self.aggregates)));
        }
        while let Some(row) = input.next(ctx)? {
            let g = if self.group_by.is_empty() {
                0
            } else {
                let mut key = Vec::with_capacity(self.group_by.len());
                for e in &self.group_by {
                    key.push(eval(e, &row, ctx)?);
                }
                match index.get(&key) {
                    Some(&g) => g,
                    None => {
                        ctx.reserve(key.iter().map(|v| v.approx_size()).sum::<usize>() * 2 + 64)?;
                        groups.push((key.clone(), new_states(&self.aggregates)));
                        index.insert(key, groups.len() - 1);
                        groups.len() - 1
                    }
                }
            };
            let states = &mut groups[g].1;
            for (state, call) in states.iter_mut().zip(&self.aggregates) {
                let v = match &call.arg {
                    Some(arg) => eval(arg, &row, ctx)?,
                    None => Value::Null,
                };
                let retained = state.update(&v)?;
                if retained > 0 {
                    ctx.reserve(retained)?;
                }
            }
        }
        let mut out = Vec::with_capacity(groups.len());
        for (key, states) in groups {
            let mut row = key;
            for s in &states {
                row.push(s.finish()?);
            }
            out.push(row);
        }
        Ok(out)
    }
}

impl Operator for AggregateOp {
    fn next(&mut self, ctx: &ExecContext) -> Result<Option<Row>> {
        if let Some(input) = self.input.take() {
            self.output = self.compute(input, ctx)?.into_iter();
        }
        Ok(self.output.next())
    }
}

/// Compares two sort-key values honoring direction and NULL placement.
pub fn compare_keys(a: &Value, b: &Value, key: &SortKey) -> Ordering {
    match (a.is_null(), b.is_null()) {
        (true, true) => Ordering::Equal,
        (true, false) => {
            if key.nulls_first {
                Ordering::Less
            } else {
                Ordering::Greater
            }
        }
        (false, true) => {
            if key.nulls_first {
                Ordering::Greater
            } else {
                Ordering::Less
            }
        }
        (false, false) => {
            let o = a.sort_cmp(b);
            if key.descending { o.reverse() } else { o }
        }
    }
}

/// Sorts its input; with `top = Some(n)` only the first n rows are kept
/// (top-N selection with bounded memory).
struct SortOp {
    input: Option<Box<dyn Operator>>,
    keys: Vec<SortKey>,
    top: Option<usize>,
    output: std::vec::IntoIter<Row>,
}

type SortEntry = (Vec<Value>, Row);

impl SortOp {
    fn new(input: Box<dyn Operator>, keys: Vec<SortKey>, top: Option<usize>) -> Self {
        SortOp {
            input: Some(input),
            keys,
            top,
            output: Vec::new().into_iter(),
        }
    }

    fn compare(&self, a: &SortEntry, b: &SortEntry) -> Ordering {
        for (i, k) in self.keys.iter().enumerate() {
            let o = compare_keys(&a.0[i], &b.0[i], k);
            if o != Ordering::Equal {
                return o;
            }
        }
        Ordering::Equal
    }

    /// Keeps only the `n` smallest entries.
    fn truncate_top(&self, entries: &mut Vec<SortEntry>, n: usize, ctx: &ExecContext) {
        if entries.len() > n {
            if n > 0 {
                entries.select_nth_unstable_by(n - 1, |a, b| self.compare(a, b));
            }
            let freed: usize = entries[n..].iter().map(entry_size).sum();
            entries.truncate(n);
            ctx.release(freed);
        }
    }

    fn compute(&self, mut input: Box<dyn Operator>, ctx: &ExecContext) -> Result<Vec<Row>> {
        let mut entries: Vec<SortEntry> = Vec::new();
        while let Some(row) = input.next(ctx)? {
            let mut key = Vec::with_capacity(self.keys.len());
            for k in &self.keys {
                key.push(eval(&k.expr, &row, ctx)?);
            }
            let entry = (key, row);
            ctx.reserve(entry_size(&entry))?;
            entries.push(entry);
            if let Some(n) = self.top
                && entries.len() >= n.saturating_mul(2).max(1024)
            {
                self.truncate_top(&mut entries, n, ctx);
            }
        }
        if let Some(n) = self.top {
            self.truncate_top(&mut entries, n, ctx);
        }
        ctx.check_interrupt()?;
        entries.sort_by(|a, b| self.compare(a, b));
        Ok(entries.into_iter().map(|(_, row)| row).collect())
    }
}

fn entry_size(e: &SortEntry) -> usize {
    e.0.iter()
        .chain(e.1.iter())
        .map(|v| v.approx_size())
        .sum::<usize>()
        + 48
}

impl Operator for SortOp {
    fn next(&mut self, ctx: &ExecContext) -> Result<Option<Row>> {
        if let Some(input) = self.input.take() {
            self.output = self.compute(input, ctx)?.into_iter();
        }
        Ok(self.output.next())
    }
}

struct LimitOp {
    input: Box<dyn Operator>,
    offset: u64,
    remaining: Option<u64>,
}

impl Operator for LimitOp {
    fn next(&mut self, ctx: &ExecContext) -> Result<Option<Row>> {
        if self.remaining == Some(0) {
            return Ok(None);
        }
        while self.offset > 0 {
            if self.input.next(ctx)?.is_none() {
                return Ok(None);
            }
            self.offset -= 1;
        }
        let row = self.input.next(ctx)?;
        if row.is_some()
            && let Some(r) = &mut self.remaining
        {
            *r -= 1;
        }
        Ok(row)
    }
}
