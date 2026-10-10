//! Physical operators (pull-based, row-at-a-time iterator model).

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet, VecDeque};
use std::rc::Rc;
use std::sync::Arc;

use super::aggregate::AggState;
use super::context::{ExecContext, LookupTable};
use super::eval::{eval, eval_predicate, normalize_key};
use crate::error::Result;
use crate::planner::expr::{AggregateCall, Expr, KeyDomain};
use crate::planner::logical::{JoinType, SortKey};
use crate::planner::physical::{JoinKey, PhysicalPlan};
use crate::storage::Table;
use crate::types::Value;

pub type Row = Vec<Value>;

/// Rows between interruption checks in tight loops.
const CHECK_INTERVAL: usize = 1024;

pub trait Operator {
    /// Produces the next row, or None when exhausted.
    fn next(&mut self, ctx: &ExecContext) -> Result<Option<Row>>;
}

/// Builds the operator tree for a physical plan.
pub fn build(plan: PhysicalPlan) -> Box<dyn Operator> {
    match plan {
        PhysicalPlan::Values => Box::new(SingleRowOp { done: false }),
        PhysicalPlan::TableScan { table, columns, .. } => Box::new(ScanOp {
            table,
            columns,
            pos: 0,
        }),
        PhysicalPlan::Filter { input, predicate } => Box::new(FilterOp {
            input: build(*input),
            predicate,
        }),
        PhysicalPlan::Project { input, exprs, .. } => Box::new(ProjectOp {
            input: build(*input),
            exprs,
        }),
        PhysicalPlan::HashAggregate {
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
        PhysicalPlan::HashJoin {
            left,
            right,
            join_type,
            keys,
            residual,
            build_left,
            ..
        } => {
            let left_width = left.schema().len();
            let right_width = right.schema().len();
            let (probe, build_side) = if build_left {
                (right, left)
            } else {
                (left, right)
            };
            Box::new(HashJoinOp {
                probe: build(*probe),
                build_input: Some(build(*build_side)),
                keys,
                residual,
                left_join: join_type == JoinType::Left,
                build_left,
                left_width,
                right_width,
                table: HashMap::new(),
                build_rows: Vec::new(),
                out: VecDeque::new(),
            })
        }
        PhysicalPlan::NestedLoopJoin {
            left,
            right,
            join_type,
            predicate,
            ..
        } => {
            let right_width = right.schema().len();
            Box::new(NestedLoopJoinOp {
                left: build(*left),
                right_input: Some(build(*right)),
                right_rows: Vec::new(),
                predicate,
                left_join: join_type == JoinType::Left,
                right_width,
                out: VecDeque::new(),
            })
        }
        PhysicalPlan::ParamLookup {
            id,
            input,
            keys,
            residual,
        } => Box::new(ParamLookupOp {
            id,
            input: Some(input),
            keys,
            residual,
            matches: None,
            pos: 0,
        }),
        PhysicalPlan::Distinct { input } => Box::new(DistinctOp {
            input: build(*input),
            seen: HashSet::new(),
        }),
        PhysicalPlan::Sort { input, keys, top } => Box::new(SortOp::new(build(*input), keys, top)),
        PhysicalPlan::Limit {
            input,
            offset,
            limit,
        } => Box::new(LimitOp {
            input: build(*input),
            offset,
            remaining: limit,
        }),
    }
}

/// Approximate retained size of a materialized row.
fn row_size(row: &[Value]) -> usize {
    row.iter().map(|v| v.approx_size()).sum::<usize>() + 24
}

/// Evaluates join key expressions; None if any key is NULL (never matches).
fn join_key(
    exprs: &mut dyn Iterator<Item = (&Expr, KeyDomain)>,
    row: &[Value],
    ctx: &ExecContext,
) -> Result<Option<Vec<Value>>> {
    let mut key = Vec::new();
    for (e, domain) in exprs {
        let v = eval(e, row, ctx)?;
        if v.is_null() {
            return Ok(None);
        }
        key.push(normalize_key(v, domain));
    }
    Ok(Some(key))
}

/// Hash equi-join. The build side is materialized into a hash table on its
/// key values; the probe side streams. For LEFT joins the probe side is the
/// left input and unmatched probe rows are padded with NULLs.
struct HashJoinOp {
    probe: Box<dyn Operator>,
    build_input: Option<Box<dyn Operator>>,
    keys: Vec<JoinKey>,
    residual: Option<Expr>,
    left_join: bool,
    /// The build side is the left input (output columns stay left ++ right).
    build_left: bool,
    left_width: usize,
    right_width: usize,
    table: HashMap<Vec<Value>, Vec<usize>>,
    build_rows: Vec<Row>,
    out: VecDeque<Row>,
}

impl HashJoinOp {
    fn build_keys(&self) -> impl Iterator<Item = (&Expr, KeyDomain)> {
        self.keys
            .iter()
            .map(move |k| (if self.build_left { &k.left } else { &k.right }, k.domain))
    }

    fn probe_keys(&self) -> impl Iterator<Item = (&Expr, KeyDomain)> {
        self.keys
            .iter()
            .map(move |k| (if self.build_left { &k.right } else { &k.left }, k.domain))
    }

    fn build_table(&mut self, mut input: Box<dyn Operator>, ctx: &ExecContext) -> Result<()> {
        while let Some(row) = input.next(ctx)? {
            let key = join_key(&mut self.build_keys(), &row, ctx)?;
            if let Some(key) = key {
                ctx.reserve(row_size(&row) + row_size(&key))?;
                self.table
                    .entry(key)
                    .or_default()
                    .push(self.build_rows.len());
                self.build_rows.push(row);
            }
        }
        Ok(())
    }

    /// Joins one probe row, queueing the output rows.
    fn probe_row(&mut self, row: Row, ctx: &ExecContext) -> Result<()> {
        let key = join_key(&mut self.probe_keys(), &row, ctx)?;
        let mut matched = false;
        if let Some(candidates) = key.as_ref().and_then(|k| self.table.get(k)) {
            for &i in candidates {
                let other = &self.build_rows[i];
                let mut combined = Vec::with_capacity(self.left_width + self.right_width);
                if self.build_left {
                    combined.extend_from_slice(other);
                    combined.extend_from_slice(&row);
                } else {
                    combined.extend_from_slice(&row);
                    combined.extend_from_slice(other);
                }
                if let Some(r) = &self.residual
                    && !eval_predicate(r, &combined, ctx)?
                {
                    continue;
                }
                matched = true;
                ctx.count_join_rows(1)?;
                self.out.push_back(combined);
            }
        }
        if !matched && self.left_join {
            let mut padded = row;
            padded.resize(self.left_width + self.right_width, Value::Null);
            ctx.count_join_rows(1)?;
            self.out.push_back(padded);
        }
        Ok(())
    }
}

impl Operator for HashJoinOp {
    fn next(&mut self, ctx: &ExecContext) -> Result<Option<Row>> {
        if let Some(input) = self.build_input.take() {
            self.build_table(input, ctx)?;
        }
        loop {
            if let Some(row) = self.out.pop_front() {
                return Ok(Some(row));
            }
            match self.probe.next(ctx)? {
                Some(row) => self.probe_row(row, ctx)?,
                None => return Ok(None),
            }
        }
    }
}

/// Nested-loop join (any predicate, CROSS joins). The right input is
/// materialized once.
struct NestedLoopJoinOp {
    left: Box<dyn Operator>,
    right_input: Option<Box<dyn Operator>>,
    right_rows: Vec<Row>,
    predicate: Option<Expr>,
    left_join: bool,
    right_width: usize,
    out: VecDeque<Row>,
}

impl Operator for NestedLoopJoinOp {
    fn next(&mut self, ctx: &ExecContext) -> Result<Option<Row>> {
        if let Some(mut input) = self.right_input.take() {
            while let Some(row) = input.next(ctx)? {
                ctx.reserve(row_size(&row))?;
                self.right_rows.push(row);
            }
        }
        loop {
            if let Some(row) = self.out.pop_front() {
                return Ok(Some(row));
            }
            let Some(left) = self.left.next(ctx)? else {
                return Ok(None);
            };
            let mut matched = false;
            for (i, right) in self.right_rows.iter().enumerate() {
                if i % CHECK_INTERVAL == CHECK_INTERVAL - 1 {
                    ctx.check_interrupt()?;
                }
                let mut combined = Vec::with_capacity(left.len() + right.len());
                combined.extend_from_slice(&left);
                combined.extend_from_slice(right);
                if let Some(p) = &self.predicate
                    && !eval_predicate(p, &combined, ctx)?
                {
                    continue;
                }
                matched = true;
                ctx.count_join_rows(1)?;
                self.out.push_back(combined);
            }
            if !matched && self.left_join {
                let mut padded = left;
                padded.resize(padded.len() + self.right_width, Value::Null);
                ctx.count_join_rows(1)?;
                self.out.push_back(padded);
            }
        }
    }
}

/// Probes a per-query hash table of a parameter-independent input with the
/// current correlation parameters (see `PhysicalPlan::ParamLookup`).
struct ParamLookupOp {
    id: usize,
    input: Option<Box<PhysicalPlan>>,
    keys: Vec<JoinKey>,
    residual: Option<Expr>,
    /// The table and probe key, once computed (None key: a NULL parameter).
    matches: Option<(Rc<LookupTable>, Option<Vec<Value>>)>,
    pos: usize,
}

impl ParamLookupOp {
    fn table(&mut self, ctx: &ExecContext) -> Result<Rc<LookupTable>> {
        if let Some(t) = ctx.cached_lookup(self.id) {
            return Ok(t);
        }
        let mut table = LookupTable::new();
        if let Some(plan) = self.input.take() {
            let mut input = build(*plan);
            while let Some(row) = input.next(ctx)? {
                let key = join_key(
                    &mut self.keys.iter().map(|k| (&k.left, k.domain)),
                    &row,
                    ctx,
                )?;
                if let Some(key) = key {
                    ctx.reserve(row_size(&row) + row_size(&key))?;
                    table.entry(key).or_default().push(row);
                }
            }
        }
        let table = Rc::new(table);
        ctx.cache_lookup(self.id, table.clone());
        Ok(table)
    }
}

impl Operator for ParamLookupOp {
    fn next(&mut self, ctx: &ExecContext) -> Result<Option<Row>> {
        if self.matches.is_none() {
            let table = self.table(ctx)?;
            let key = join_key(
                &mut self.keys.iter().map(|k| (&k.right, k.domain)),
                &[],
                ctx,
            )?;
            self.matches = Some((table, key));
        }
        let Some((table, Some(key))) = &self.matches else {
            return Ok(None);
        };
        let Some(rows) = table.get(key) else {
            return Ok(None);
        };
        while self.pos < rows.len() {
            let row = &rows[self.pos];
            self.pos += 1;
            if let Some(r) = &self.residual
                && !eval_predicate(r, row, ctx)?
            {
                continue;
            }
            return Ok(Some(row.clone()));
        }
        Ok(None)
    }
}

/// Streams the first occurrence of each distinct row.
struct DistinctOp {
    input: Box<dyn Operator>,
    seen: HashSet<Row>,
}

impl Operator for DistinctOp {
    fn next(&mut self, ctx: &ExecContext) -> Result<Option<Row>> {
        while let Some(row) = self.input.next(ctx)? {
            if !self.seen.contains(&row) {
                ctx.reserve(row_size(&row) * 2)?;
                self.seen.insert(row.clone());
                return Ok(Some(row));
            }
        }
        Ok(None)
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
