//! Filters directly above a scan of a column-oriented table, evaluated with
//! the native kernels (`native: true`).
//!
//! The predicate's conjuncts are split into *native* conjuncts — `col <op>
//! constant`, `col BETWEEN c1 AND c2`, `col1 <op> col2` over integer-
//! represented columns (INT64, DECIMAL, DATE, TIMESTAMP) and `col IS [NOT]
//! NULL` on any column — and a *residual* (everything else, in the original
//! order). Per scan window the native conjuncts run on the stored column
//! slices and validity bitmaps (`pqk_filter_i64[_bitmap]`,
//! `pqk_compare_i64`, `pqk_bitmap_and/or/andnot`, `pqk_bitmap_popcount`),
//! and only the selected rows are copied out of the table
//! (`pqk_gather_i64` for 64-bit columns). Rows a native conjunct rejects are
//! never materialized.
//!
//! Semantics are those of the original filter:
//! * Constants are converted exactly into the column's integer domain
//!   (`int_col < 2.5` becomes `int_col <= 2`, a DATE column compared with a
//!   TIMESTAMP constant is compared at day granularity, out-of-range
//!   constants become constant predicates), so the kernels decide exactly
//!   what the engine's comparison would.
//! * With a residual, every row on which no native conjunct is FALSE
//!   (including rows where one is NULL) is a candidate on which the
//!   residual is evaluated; a row qualifies if the residual is TRUE and
//!   every native conjunct is TRUE. Rows with a FALSE native conjunct
//!   cannot raise errors in the reference engine either (an error in an
//!   `AND` operand is only raised when no other operand is FALSE).
//! * Predicates that call `PQ_SLEEP` or contain subqueries are not split
//!   (their evaluation cost/timing must stay that of the reference engine).

use std::sync::Arc;

use super::eval::eval_predicate;
use super::operators::{Operator, Row};
use super::vector::batch::{Batch, Data, Vector};
use super::vector::eval::eval_mask;
use super::vector::ops::{BatchOperator, ScanRange, read_batch};
use crate::error::{Error, Result};
use crate::exec::ExecContext;
use crate::native::{CmpOp, Kernels, bitmap_bytes, bitmap_selection};
use crate::planner::expr::{Expr, ScalarFunc};
use crate::sql::ast::BinaryOp;
use crate::storage::{Column, ColumnData, Layout, Table};
use crate::types::datetime::date_to_timestamp;
use crate::types::{DataType, Value, decimal};

const MICROS_PER_DAY: i128 = 86_400_000_000;

/// Integer domain of a column type as stored in column chunks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Domain {
    Int,
    /// Unscaled values at this scale.
    Dec(u8),
    Date,
    Ts,
}

impl Domain {
    fn of(ty: DataType) -> Option<Domain> {
        Some(match ty {
            DataType::Int64 => Domain::Int,
            DataType::Decimal { scale, .. } => Domain::Dec(scale),
            DataType::Date => Domain::Date,
            DataType::Timestamp => Domain::Ts,
            _ => return None,
        })
    }

    /// A constant as the exact rational `num / den` (den > 0) in this
    /// domain's integer units; None if not comparable exactly here.
    fn rational(self, v: &Value) -> Option<(i128, i128)> {
        let scale = |s: u8| decimal::pow10(s as u32);
        Some(match (self, v) {
            (Domain::Int, Value::Int(c)) => (*c as i128, 1),
            (Domain::Int, Value::Decimal(u, k)) => (*u as i128, scale(*k)),
            (Domain::Dec(s), Value::Int(c)) => (*c as i128 * scale(s), 1),
            (Domain::Dec(s), Value::Decimal(u, k)) => (*u as i128 * scale(s), scale(*k)),
            (Domain::Ts, Value::Timestamp(t)) => (*t as i128, 1),
            (Domain::Ts, Value::Date(d)) => (date_to_timestamp(*d) as i128, 1),
            (Domain::Date, Value::Date(d)) => (*d as i128, 1),
            (Domain::Date, Value::Timestamp(t)) => (*t as i128, MICROS_PER_DAY),
            _ => return None,
        })
    }
}

/// Inclusive integer range `[lo, hi]` (None = unbounded).
type Range = (Option<i128>, Option<i128>);

/// The set of integers `x` with `x <op> num/den`, as a range (`Ne` with an
/// integral constant is returned separately).
fn range_of(op: BinaryOp, num: i128, den: i128) -> std::result::Result<Range, i128> {
    let floor = num.div_euclid(den);
    let exact = num.rem_euclid(den) == 0;
    Ok(match op {
        BinaryOp::Eq if exact => (Some(floor), Some(floor)),
        // Never equal to a non-integral constant.
        BinaryOp::Eq => (Some(1), Some(0)),
        BinaryOp::NotEq if exact => return Err(floor),
        BinaryOp::NotEq => (None, None),
        BinaryOp::Lt if exact => (None, Some(floor - 1)),
        BinaryOp::Lt | BinaryOp::LtEq => (None, Some(floor)),
        BinaryOp::Gt if exact => (Some(floor + 1), None),
        BinaryOp::GtEq if exact => (Some(floor), None),
        BinaryOp::Gt | BinaryOp::GtEq => (Some(floor + 1), None),
        _ => (Some(1), Some(0)),
    })
}

fn intersect(a: Range, b: Range) -> Range {
    let lo = match (a.0, b.0) {
        (Some(x), Some(y)) => Some(x.max(y)),
        (x, y) => x.or(y),
    };
    let hi = match (a.1, b.1) {
        (Some(x), Some(y)) => Some(x.min(y)),
        (x, y) => x.or(y),
    };
    (lo, hi)
}

/// A kernel predicate `(op, a, b)` selecting the valid rows in `range`.
fn kernel_predicate(range: Range) -> (CmpOp, i64, i64) {
    const MIN: i128 = i64::MIN as i128;
    const MAX: i128 = i64::MAX as i128;
    let lo = range.0.unwrap_or(MIN).max(MIN);
    let hi = range.1.unwrap_or(MAX).min(MAX);
    if lo > hi {
        // Empty: no valid row qualifies.
        return (CmpOp::Between, 1, 0);
    }
    let (lo, hi) = (lo as i64, hi as i64);
    match (lo == i64::MIN, hi == i64::MAX) {
        (true, true) => (CmpOp::Between, lo, hi),
        (true, false) => (CmpOp::Le, hi, 0),
        (false, true) => (CmpOp::Ge, lo, 0),
        (false, false) if lo == hi => (CmpOp::Eq, lo, 0),
        (false, false) => (CmpOp::Between, lo, hi),
    }
}

fn cmp_op(op: BinaryOp) -> Option<CmpOp> {
    Some(match op {
        BinaryOp::Eq => CmpOp::Eq,
        BinaryOp::NotEq => CmpOp::Ne,
        BinaryOp::Lt => CmpOp::Lt,
        BinaryOp::LtEq => CmpOp::Le,
        BinaryOp::Gt => CmpOp::Gt,
        BinaryOp::GtEq => CmpOp::Ge,
        _ => return None,
    })
}

fn flip(op: BinaryOp) -> BinaryOp {
    match op {
        BinaryOp::Lt => BinaryOp::Gt,
        BinaryOp::LtEq => BinaryOp::GtEq,
        BinaryOp::Gt => BinaryOp::Lt,
        BinaryOp::GtEq => BinaryOp::LtEq,
        other => other,
    }
}

/// A conjunct evaluated by the kernels (column indices are scan output
/// positions).
#[derive(Debug, Clone, PartialEq)]
enum Conjunct {
    /// `op(col, a, b)` on the column's integer representation.
    Const {
        col: usize,
        op: CmpOp,
        a: i64,
        b: i64,
    },
    /// `left <op> right`, both of the same integer domain.
    Columns {
        left: usize,
        right: usize,
        op: CmpOp,
    },
    /// `col IS NULL` (`negated`: IS NOT NULL).
    Null { col: usize, negated: bool },
}

impl Conjunct {
    fn columns(&self) -> Vec<usize> {
        match self {
            Conjunct::Const { col, .. } | Conjunct::Null { col, .. } => vec![*col],
            Conjunct::Columns { left, right, .. } => vec![*left, *right],
        }
    }
}

/// A filter over a scan, split into native conjuncts and a residual.
#[derive(Debug, Clone)]
pub struct NativeFilter {
    conjuncts: Vec<Conjunct>,
    residual: Option<Expr>,
    /// The whole predicate (windows whose chunks are not in the expected
    /// representation are filtered with it by the engine's own code).
    predicate: Expr,
}

fn column_of(e: &Expr) -> Option<(usize, DataType)> {
    match e {
        Expr::Column { index, ty } => Some((*index, *ty)),
        _ => None,
    }
}

fn literal_of(e: &Expr) -> Option<&Value> {
    match e {
        Expr::Literal { value, .. } if !value.is_null() => Some(value),
        _ => None,
    }
}

/// `col <op> constant` (either side) as a range of the column's domain.
fn const_comparison(op: BinaryOp, l: &Expr, r: &Expr) -> Option<Conjunct> {
    let ((col, ty), value, op) = match (column_of(l), literal_of(r)) {
        (Some(c), Some(v)) => (c, v, op),
        _ => (column_of(r)?, literal_of(l)?, flip(op)),
    };
    let (num, den) = Domain::of(ty)?.rational(value)?;
    cmp_op(op)?;
    Some(match range_of(op, num, den) {
        Ok(range) => {
            let (op, a, b) = kernel_predicate(range);
            Conjunct::Const { col, op, a, b }
        }
        Err(v) => match i64::try_from(v) {
            Ok(v) => Conjunct::Const {
                col,
                op: CmpOp::Ne,
                a: v,
                b: 0,
            },
            // Every valid value differs from an out-of-range constant.
            Err(_) => Conjunct::Const {
                col,
                op: CmpOp::Between,
                a: i64::MIN,
                b: i64::MAX,
            },
        },
    })
}

fn classify(e: &Expr) -> Option<Conjunct> {
    match e {
        Expr::Compare { op, left, right } => {
            if let (Some((a, ta)), Some((b, tb))) = (column_of(left), column_of(right)) {
                let (da, db) = (Domain::of(ta)?, Domain::of(tb)?);
                return (da == db).then_some(Conjunct::Columns {
                    left: a,
                    right: b,
                    op: cmp_op(*op)?,
                });
            }
            const_comparison(*op, left, right)
        }
        Expr::Between {
            expr,
            low,
            high,
            negated: false,
        } => {
            let (col, ty) = column_of(expr)?;
            let domain = Domain::of(ty)?;
            let (ln, ld) = domain.rational(literal_of(low)?)?;
            let (hn, hd) = domain.rational(literal_of(high)?)?;
            let lo = range_of(BinaryOp::GtEq, ln, ld).ok()?;
            let hi = range_of(BinaryOp::LtEq, hn, hd).ok()?;
            let (op, a, b) = kernel_predicate(intersect(lo, hi));
            Some(Conjunct::Const { col, op, a, b })
        }
        Expr::IsNull { expr, negated } => Some(Conjunct::Null {
            col: column_of(expr)?.0,
            negated: *negated,
        }),
        _ => None,
    }
}

impl NativeFilter {
    /// Number of conjuncts evaluated by the kernels.
    pub fn native_conjuncts(&self) -> usize {
        self.conjuncts.len()
    }

    /// Splits `predicate` over a scan of `columns` of `table` (None if no
    /// conjunct can use the kernels, or the table is not column-oriented).
    pub fn analyze(predicate: &Expr, table: &Table, columns: &[usize]) -> Option<NativeFilter> {
        if table.layout() != Layout::Column {
            return None;
        }
        // Column references must carry the stored column types (constants
        // are converted into the stored representation).
        let foreign = |e: &Expr| match e {
            Expr::Column { index, ty } => columns
                .get(*index)
                .is_none_or(|&c| table.fields[c].data_type != *ty),
            _ => false,
        };
        if predicate.any(&foreign) {
            return None;
        }
        let opaque = |e: &Expr| {
            matches!(
                e,
                Expr::Function {
                    func: ScalarFunc::PqSleep,
                    ..
                } | Expr::ScalarSubquery { .. }
                    | Expr::Exists { .. }
                    | Expr::InSubquery { .. }
                    | Expr::Param { .. }
            )
        };
        if predicate.any(&opaque) {
            return None;
        }
        let mut parts = Vec::new();
        predicate.clone().into_conjuncts(&mut parts);
        let mut conjuncts = Vec::new();
        let mut residual = Vec::new();
        for p in parts {
            match classify(&p) {
                Some(c) => conjuncts.push(c),
                None => residual.push(p),
            }
        }
        if conjuncts.is_empty() {
            return None;
        }
        Some(NativeFilter {
            conjuncts,
            residual: Expr::conjunction(residual),
            predicate: predicate.clone(),
        })
    }
}

/// Outcome of the native conjuncts on one window.
enum Selected {
    /// A chunk is not in the expected representation: filter this window
    /// with the engine's own code.
    Fallback,
    /// Window-relative rows passing the filter (in `Scratch::idx`).
    Rows,
    /// Candidate rows for the residual (in `Scratch::idx`); `Scratch::truth`
    /// marks the rows on which every native conjunct is TRUE.
    Candidates,
}

/// Buffers reused across windows.
#[derive(Debug, Default)]
struct Scratch {
    idx: Vec<u32>,
    truth: Vec<u8>,
    maybe: Vec<u8>,
    bits: Vec<u8>,
    nulls: Vec<u8>,
    ones: Vec<u8>,
    valid_a: Vec<u8>,
    valid_b: Vec<u8>,
    wide_a: Vec<i64>,
    wide_b: Vec<i64>,
}

/// The integer values of rows `[from, from + n)` of a chunk (DATE days
/// are widened into `buf`); None for other representations.
fn int_slice<'a>(c: &'a Column, from: usize, n: usize, buf: &'a mut Vec<i64>) -> Option<&'a [i64]> {
    match &c.data {
        ColumnData::Int64(v) | ColumnData::Decimal(v) | ColumnData::Timestamp(v) => {
            Some(&v[from..from + n])
        }
        ColumnData::Date(v) => {
            buf.clear();
            buf.extend(v[from..from + n].iter().map(|&d| d as i64));
            Some(buf)
        }
        _ => None,
    }
}

/// True if the chunk's representation is the one the analysis assumed.
fn representation_ok(c: &Column, ty: DataType) -> bool {
    matches!(
        (&c.data, ty),
        (ColumnData::Int64(_), DataType::Int64)
            | (ColumnData::Decimal(_), DataType::Decimal { .. })
            | (ColumnData::Date(_), DataType::Date)
            | (ColumnData::Timestamp(_), DataType::Timestamp)
    ) && c.data_type == ty
}

impl NativeFilter {
    /// Runs the native conjuncts on rows `[from, from + n)` of the chunks
    /// (`chunks[i]` is scan output column `i`).
    fn select(
        &self,
        k: &Kernels,
        chunks: &[&Column],
        types: &[DataType],
        from: usize,
        n: usize,
        s: &mut Scratch,
    ) -> Selected {
        for c in &self.conjuncts {
            let typed = !matches!(c, Conjunct::Null { .. });
            if typed
                && c.columns()
                    .iter()
                    .any(|&i| !representation_ok(chunks[i], types[i]))
            {
                return Selected::Fallback;
            }
        }
        s.idx.clear();
        let residual = self.residual.is_some();
        // Single comparison, no residual: the selection kernel directly.
        if let ([Conjunct::Const { col, op, a, b }], false) = (self.conjuncts.as_slice(), residual)
        {
            let c = chunks[*col];
            c.validity.copy_lsb_bytes(from, n, &mut s.valid_a);
            let Some(data) = int_slice(c, from, n, &mut s.wide_a) else {
                return Selected::Fallback;
            };
            k.filter_i64(data, Some(&s.valid_a), *op, *a, *b, &mut s.idx);
            return Selected::Rows;
        }
        let nb = bitmap_bytes(n);
        s.ones.clear();
        s.ones.resize(nb, 0xff);
        if !n.is_multiple_of(8) {
            s.ones[nb - 1] = (1u8 << (n % 8)) - 1;
        }
        s.truth.clear();
        s.truth.extend_from_slice(&s.ones);
        if residual {
            s.maybe.clear();
            s.maybe.extend_from_slice(&s.ones);
        }
        for conj in &self.conjuncts {
            // `bits`: conjunct TRUE; `nulls`: conjunct NULL (residual only).
            let mut has_nulls = false;
            match conj {
                Conjunct::Const { col, op, a, b } => {
                    let c = chunks[*col];
                    c.validity.copy_lsb_bytes(from, n, &mut s.valid_a);
                    let Some(data) = int_slice(c, from, n, &mut s.wide_a) else {
                        return Selected::Fallback;
                    };
                    k.filter_i64_bitmap(data, Some(&s.valid_a), *op, *a, *b, &mut s.bits);
                    if residual {
                        s.nulls.resize(nb, 0);
                        k.bitmap_andnot(&s.ones, &s.valid_a, &mut s.nulls);
                        has_nulls = true;
                    }
                }
                Conjunct::Columns { left, right, op } => {
                    let (cl, cr) = (chunks[*left], chunks[*right]);
                    cl.validity.copy_lsb_bytes(from, n, &mut s.valid_a);
                    cr.validity.copy_lsb_bytes(from, n, &mut s.valid_b);
                    let (Some(da), Some(db)) = (
                        int_slice(cl, from, n, &mut s.wide_a),
                        int_slice(cr, from, n, &mut s.wide_b),
                    ) else {
                        return Selected::Fallback;
                    };
                    k.compare_i64(da, db, *op, &mut s.bits);
                    k.bitmap_and_assign(&mut s.valid_a, &s.valid_b);
                    k.bitmap_and_assign(&mut s.bits, &s.valid_a);
                    if residual {
                        s.nulls.resize(nb, 0);
                        k.bitmap_andnot(&s.ones, &s.valid_a, &mut s.nulls);
                        has_nulls = true;
                    }
                }
                Conjunct::Null { col, negated } => {
                    chunks[*col]
                        .validity
                        .copy_lsb_bytes(from, n, &mut s.valid_a);
                    s.bits.resize(nb, 0);
                    if *negated {
                        s.bits.copy_from_slice(&s.valid_a);
                    } else {
                        k.bitmap_andnot(&s.ones, &s.valid_a, &mut s.bits);
                    }
                }
            }
            k.bitmap_and_assign(&mut s.truth, &s.bits);
            if residual {
                if has_nulls {
                    k.bitmap_or_assign(&mut s.bits, &s.nulls);
                }
                k.bitmap_and_assign(&mut s.maybe, &s.bits);
            }
        }
        if residual {
            bitmap_selection(&s.maybe, n, &mut s.idx);
            return Selected::Candidates;
        }
        match k.popcount(&s.truth, n) {
            0 => {}
            c if c == n => s.idx.extend(0..n as u32),
            _ => bitmap_selection(&s.truth, n, &mut s.idx),
        }
        Selected::Rows
    }
}

#[inline]
fn bit(bits: &[u8], i: usize) -> bool {
    bits[i / 8] >> (i % 8) & 1 == 1
}

/// Rows `from + idx[j]` of a chunk as a vector (`pqk_gather_i64` for
/// 64-bit representations).
fn gather_column(k: &Kernels, c: &Column, from: usize, idx: &[u32]) -> Vector {
    let valid: Vec<bool> = idx
        .iter()
        .map(|&i| c.validity.get(from + i as usize))
        .collect();
    let valid = (!valid.iter().all(|&v| v)).then_some(valid);
    let pick = |v: &[i64]| {
        let mut out = Vec::with_capacity(idx.len());
        k.gather_i64(&v[from..], idx, &mut out);
        out
    };
    fn take<T: Clone>(v: &[T], from: usize, idx: &[u32]) -> Vec<T> {
        idx.iter().map(|&i| v[from + i as usize].clone()).collect()
    }
    let data = match &c.data {
        ColumnData::Int64(v) => Data::Int(pick(v)),
        ColumnData::Timestamp(v) => Data::Timestamp(pick(v)),
        ColumnData::Decimal(v) => {
            let scale = match c.data_type {
                DataType::Decimal { scale, .. } => scale,
                _ => 0,
            };
            Data::Decimal(pick(v), scale)
        }
        ColumnData::Boolean(v) => Data::Bool(take(v, from, idx)),
        ColumnData::Float64(v) => Data::Float(take(v, from, idx)),
        ColumnData::String(v) => Data::Str(take(v, from, idx)),
        ColumnData::Dict { codes, dict } => Data::Dict(take(codes, from, idx), dict.clone()),
        ColumnData::Date(v) => Data::Date(take(v, from, idx)),
    };
    Vector::new(data, valid)
}

/// Iterates the scan windows (≤ `BATCH_SIZE` rows) of a list of ranges.
#[derive(Debug)]
struct Windows {
    ranges: Vec<ScanRange>,
    range: usize,
    pos: usize,
}

impl Windows {
    fn new(ranges: Vec<ScanRange>) -> Windows {
        let pos = ranges.first().map_or(0, |r| r.from);
        Windows {
            ranges,
            range: 0,
            pos,
        }
    }

    /// The next window `(group, from, to)`.
    fn next(&mut self) -> Option<(usize, usize, usize)> {
        loop {
            let r = *self.ranges.get(self.range)?;
            if self.pos >= r.to {
                self.range += 1;
                if let Some(next) = self.ranges.get(self.range) {
                    self.pos = next.from;
                }
                continue;
            }
            let to = (self.pos + super::vector::batch::BATCH_SIZE).min(r.to);
            let from = self.pos;
            self.pos = to;
            return Some((r.group, from, to));
        }
    }
}

/// The chunks of the scanned columns in row group `rg` (in column order, so
/// a corrupt chunk reports the same error as a plain scan).
fn chunks<'a>(table: &'a Table, columns: &[usize], rg: usize) -> Result<Vec<&'a Column>> {
    columns
        .iter()
        .map(|&c| {
            table
                .column_chunk(rg, c)?
                .ok_or_else(|| Error::internal("native filter over a row-layout table"))
        })
        .collect()
}

/// Vectorized scan + filter using the native kernels.
pub struct NativeFilterScanOp {
    table: Arc<Table>,
    columns: Vec<usize>,
    types: Vec<DataType>,
    windows: Windows,
    filter: Arc<NativeFilter>,
    kernels: &'static Kernels,
    scratch: Scratch,
}

impl NativeFilterScanOp {
    pub fn new(
        table: Arc<Table>,
        columns: Vec<usize>,
        ranges: Vec<ScanRange>,
        filter: Arc<NativeFilter>,
        kernels: &'static Kernels,
    ) -> NativeFilterScanOp {
        let types = columns.iter().map(|&c| table.fields[c].data_type).collect();
        NativeFilterScanOp {
            table,
            columns,
            types,
            windows: Windows::new(ranges),
            filter,
            kernels,
            scratch: Scratch::default(),
        }
    }

    fn gather(&self, chunks: &[&Column], from: usize, n: usize) -> Batch {
        let idx = &self.scratch.idx;
        let cols = if idx.len() == n {
            chunks
                .iter()
                .map(|c| Vector::from_column(c, from, from + n))
                .collect()
        } else {
            chunks
                .iter()
                .map(|c| gather_column(self.kernels, c, from, idx))
                .collect()
        };
        Batch::new(cols, idx.len())
    }
}

impl BatchOperator for NativeFilterScanOp {
    fn next_batch(&mut self, ctx: &ExecContext) -> Result<Option<Batch>> {
        while let Some((rg, from, to)) = self.windows.next() {
            ctx.check_interrupt()?;
            let n = to - from;
            let table = self.table.clone();
            let chunks = chunks(&table, &self.columns, rg)?;
            let selected = self.filter.select(
                self.kernels,
                &chunks,
                &self.types,
                from,
                n,
                &mut self.scratch,
            );
            match selected {
                Selected::Fallback => {
                    let b = read_batch(&self.table, &self.columns, rg, from, to)?;
                    let mask = eval_mask(&self.filter.predicate, &b, ctx)?;
                    let kept = mask.iter().filter(|&&m| m).count();
                    if kept == b.len {
                        return Ok(Some(b));
                    }
                    if kept > 0 {
                        return Ok(Some(b.filter(&mask)));
                    }
                }
                Selected::Rows => {
                    if !self.scratch.idx.is_empty() {
                        return Ok(Some(self.gather(&chunks, from, n)));
                    }
                }
                Selected::Candidates => {
                    if self.scratch.idx.is_empty() {
                        continue;
                    }
                    let b = self.gather(&chunks, from, n);
                    let residual = self.filter.residual.as_ref().expect("residual");
                    let mut mask = eval_mask(residual, &b, ctx)?;
                    for (m, &i) in mask.iter_mut().zip(&self.scratch.idx) {
                        *m &= bit(&self.scratch.truth, i as usize);
                    }
                    let kept = mask.iter().filter(|&&m| m).count();
                    if kept == b.len {
                        return Ok(Some(b));
                    }
                    if kept > 0 {
                        return Ok(Some(b.filter(&mask)));
                    }
                }
            }
        }
        Ok(None)
    }
}

/// Row-at-a-time scan + filter using the native kernels: the kernels
/// select candidate rows per window, the residual is evaluated per row by
/// the row evaluator (row-mode semantics, including the error of the
/// first failing row after all earlier qualifying rows were produced).
pub struct NativeFilterRowOp {
    table: Arc<Table>,
    columns: Vec<usize>,
    types: Vec<DataType>,
    windows: Windows,
    filter: Arc<NativeFilter>,
    kernels: &'static Kernels,
    scratch: Scratch,
    rows: std::vec::IntoIter<Row>,
    /// Error raised after the buffered rows have been returned.
    pending: Option<Error>,
}

impl NativeFilterRowOp {
    pub fn new(
        table: Arc<Table>,
        columns: Vec<usize>,
        ranges: Vec<ScanRange>,
        filter: Arc<NativeFilter>,
        kernels: &'static Kernels,
    ) -> NativeFilterRowOp {
        let types = columns.iter().map(|&c| table.fields[c].data_type).collect();
        NativeFilterRowOp {
            table,
            columns,
            types,
            windows: Windows::new(ranges),
            filter,
            kernels,
            scratch: Scratch::default(),
            rows: Vec::new().into_iter(),
            pending: None,
        }
    }

    /// Fills the row buffer from the next window(s); false at the end.
    fn fill(&mut self, ctx: &ExecContext) -> Result<bool> {
        let row_at =
            |chunks: &[&Column], i: usize| -> Row { chunks.iter().map(|c| c.value(i)).collect() };
        while let Some((rg, from, to)) = self.windows.next() {
            ctx.check_interrupt()?;
            let n = to - from;
            let table = self.table.clone();
            let chunks = chunks(&table, &self.columns, rg)?;
            let selected = self.filter.select(
                self.kernels,
                &chunks,
                &self.types,
                from,
                n,
                &mut self.scratch,
            );
            let mut out = Vec::new();
            let mut pending = None;
            // Evaluates the remaining predicate on a row; false stops the
            // window at an error.
            let mut test = |row: Row, pred: Option<&Expr>, native_true: bool| -> bool {
                match pred.map(|p| eval_predicate(p, &row, ctx)) {
                    Some(Err(e)) => {
                        pending = Some(e);
                        false
                    }
                    Some(Ok(true)) | None if native_true => {
                        out.push(row);
                        true
                    }
                    _ => true,
                }
            };
            match selected {
                Selected::Fallback => {
                    for i in from..to {
                        if !test(row_at(&chunks, i), Some(&self.filter.predicate), true) {
                            break;
                        }
                    }
                }
                Selected::Rows => {
                    for &i in &self.scratch.idx {
                        test(row_at(&chunks, from + i as usize), None, true);
                    }
                }
                Selected::Candidates => {
                    let residual = self.filter.residual.as_ref();
                    for &i in &self.scratch.idx {
                        let t = bit(&self.scratch.truth, i as usize);
                        if !test(row_at(&chunks, from + i as usize), residual, t) {
                            break;
                        }
                    }
                }
            }
            self.pending = pending;
            let stop = self.pending.is_some();
            if !out.is_empty() || stop {
                self.rows = out.into_iter();
                return Ok(true);
            }
        }
        Ok(false)
    }
}

impl Operator for NativeFilterRowOp {
    fn next(&mut self, ctx: &ExecContext) -> Result<Option<Row>> {
        loop {
            if let Some(r) = self.rows.next() {
                return Ok(Some(r));
            }
            if let Some(e) = self.pending.take() {
                // Stop for good after reporting the error.
                self.windows.range = self.windows.ranges.len();
                return Err(e);
            }
            if !self.fill(ctx)? {
                return Ok(None);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::Field;

    fn col(index: usize, ty: DataType) -> Box<Expr> {
        Box::new(Expr::Column { index, ty })
    }

    fn lit(value: Value, ty: DataType) -> Box<Expr> {
        Box::new(Expr::Literal { value, ty })
    }

    fn cmp(op: BinaryOp, l: Box<Expr>, r: Box<Expr>) -> Expr {
        Expr::Compare {
            op,
            left: l,
            right: r,
        }
    }

    #[test]
    fn exact_constant_conversion() {
        let dec = DataType::decimal(18, 1);
        let int = DataType::Int64;
        // int < 2.5  ⇔  int <= 2
        let c = classify(&cmp(
            BinaryOp::Lt,
            col(0, int),
            lit(Value::Decimal(25, 1), dec),
        ));
        assert_eq!(
            c,
            Some(Conjunct::Const {
                col: 0,
                op: CmpOp::Le,
                a: 2,
                b: 0
            })
        );
        // 2.5 < int  ⇔  int >= 3
        let c = classify(&cmp(
            BinaryOp::Lt,
            lit(Value::Decimal(25, 1), dec),
            col(0, int),
        ));
        assert_eq!(
            c,
            Some(Conjunct::Const {
                col: 0,
                op: CmpOp::Ge,
                a: 3,
                b: 0
            })
        );
        // int = 2.5 never holds; int <> 2.5 always holds (for valid rows).
        let eq = classify(&cmp(
            BinaryOp::Eq,
            col(0, int),
            lit(Value::Decimal(25, 1), dec),
        ));
        assert_eq!(
            eq,
            Some(Conjunct::Const {
                col: 0,
                op: CmpOp::Between,
                a: 1,
                b: 0
            })
        );
        // decimal(18,1) column >= 3 ⇔ unscaled >= 30
        let c = classify(&cmp(BinaryOp::GtEq, col(1, dec), lit(Value::Int(3), int)));
        assert_eq!(
            c,
            Some(Conjunct::Const {
                col: 1,
                op: CmpOp::Ge,
                a: 30,
                b: 0
            })
        );
        // DATE column < TIMESTAMP '1970-01-02 00:00:01' ⇔ day <= 1
        let c = classify(&cmp(
            BinaryOp::Lt,
            col(2, DataType::Date),
            lit(Value::Timestamp(86_400_000_001), DataType::Timestamp),
        ));
        assert_eq!(
            c,
            Some(Conjunct::Const {
                col: 2,
                op: CmpOp::Le,
                a: 1,
                b: 0
            })
        );
        // Floats and strings are not native.
        assert!(
            classify(&cmp(
                BinaryOp::Lt,
                col(0, int),
                lit(Value::Float(1.5), DataType::Float64)
            ))
            .is_none()
        );
    }

    #[test]
    fn range_semantics_match_comparison() {
        // Brute force: x <op> num/den for small x and constants.
        let ops = [
            BinaryOp::Eq,
            BinaryOp::NotEq,
            BinaryOp::Lt,
            BinaryOp::LtEq,
            BinaryOp::Gt,
            BinaryOp::GtEq,
        ];
        for op in ops {
            for num in -25i128..25 {
                for den in [1i128, 2, 10] {
                    let (kop, a, b) = match range_of(op, num, den) {
                        Ok(r) => kernel_predicate(r),
                        Err(v) => (CmpOp::Ne, v as i64, 0),
                    };
                    for x in -15i64..15 {
                        let lhs = x as i128 * den;
                        let expect = match op {
                            BinaryOp::Eq => lhs == num,
                            BinaryOp::NotEq => lhs != num,
                            BinaryOp::Lt => lhs < num,
                            BinaryOp::LtEq => lhs <= num,
                            BinaryOp::Gt => lhs > num,
                            _ => lhs >= num,
                        };
                        assert_eq!(kop.eval(x, a, b), expect, "{x} {op:?} {num}/{den}");
                    }
                }
            }
        }
    }

    #[test]
    fn residual_keeps_other_conjuncts_in_order() {
        let int = DataType::Int64;
        let p = Expr::And(
            Box::new(Expr::And(
                Box::new(cmp(BinaryOp::Gt, col(0, int), col(1, DataType::Float64))),
                Box::new(cmp(BinaryOp::Gt, col(0, int), lit(Value::Int(5), int))),
            )),
            Box::new(Expr::IsNull {
                expr: col(2, DataType::String),
                negated: true,
            }),
        );
        let fields = vec![
            Field::new("a", int),
            Field::new("b", DataType::Float64),
            Field::new("c", DataType::String),
        ];
        let table = Table::new("t", fields, Vec::new(), 0);
        let f = NativeFilter::analyze(&p, &table, &[0, 1, 2]).unwrap();
        assert!(NativeFilter::analyze(&p, &table, &[0, 1]).is_none());
        assert_eq!(f.conjuncts.len(), 2);
        assert!(matches!(f.residual, Some(Expr::Compare { .. })));
    }
}
