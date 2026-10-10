//! Access-path selection for table scans (indexes-and-planning.md §3):
//! recognizing `column <op> constant` conjuncts, estimating their
//! selectivity from table statistics, choosing an index scan when it is
//! selective enough, and row-group skipping from chunk min/max statistics.

use std::cmp::Ordering;
use std::fmt;
use std::sync::Arc;

use super::expr::Expr;
use crate::exec::eval::eval_constant;
use crate::sql::ast::BinaryOp;
use crate::storage::index::Bound;
use crate::storage::{ColumnStats, Index, IndexKind, Table, Zone};
use crate::types::{DataType, Value, decimal};

/// Index scans are chosen at or below this estimated selectivity…
pub const INDEX_SELECTIVITY: f64 = 0.10;
/// …or when at most this many rows are expected (on tiny tables a lookup is
/// never worse than a scan).
pub const INDEX_MAX_TINY_ROWS: f64 = 10.0;
/// Selectivity of conjuncts that cannot be estimated from statistics.
pub const DEFAULT_SELECTIVITY: f64 = 1.0 / 3.0;

/// A conjunct restricting a single column to constant values.
#[derive(Debug, Clone, PartialEq)]
pub enum ColumnPredicate {
    /// Never TRUE (a comparison with a NULL constant).
    Never,
    Eq(Value),
    /// Non-NULL list values (`IN`).
    In(Vec<Value>),
    Range {
        lo: Option<Bound>,
        hi: Option<Bound>,
    },
    Ne(Value),
    IsNull,
    IsNotNull,
}

/// Evaluates a constant expression at planning time (None if it is not
/// constant or fails; a failure is then raised normally at execution).
fn constant(e: &Expr) -> Option<Value> {
    if !e.is_constant() {
        return None;
    }
    eval_constant(e).ok()
}

fn column_of(e: &Expr) -> Option<usize> {
    match e {
        Expr::Column { index, .. } => Some(*index),
        _ => None,
    }
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

fn bound(value: Value, inclusive: bool) -> Option<Bound> {
    Some(Bound { value, inclusive })
}

/// Recognizes `col op c`, `c op col`, `col [NOT] BETWEEN c1 AND c2`,
/// `col IN (c, …)` and `col IS [NOT] NULL` (column = input column index).
pub fn analyze(conjunct: &Expr) -> Option<(usize, ColumnPredicate)> {
    use ColumnPredicate as P;
    match conjunct {
        Expr::Compare { op, left, right } => {
            let (col, value, op) = match (column_of(left), column_of(right)) {
                (Some(c), _) => (c, constant(right)?, *op),
                (None, Some(c)) => (c, constant(left)?, flip(*op)),
                _ => return None,
            };
            if value.is_null() {
                return Some((col, P::Never));
            }
            let pred = match op {
                BinaryOp::Eq => P::Eq(value),
                BinaryOp::NotEq => P::Ne(value),
                BinaryOp::Lt => P::Range {
                    lo: None,
                    hi: bound(value, false),
                },
                BinaryOp::LtEq => P::Range {
                    lo: None,
                    hi: bound(value, true),
                },
                BinaryOp::Gt => P::Range {
                    lo: bound(value, false),
                    hi: None,
                },
                BinaryOp::GtEq => P::Range {
                    lo: bound(value, true),
                    hi: None,
                },
                _ => return None,
            };
            Some((col, pred))
        }
        Expr::Between {
            expr,
            low,
            high,
            negated: false,
        } => {
            let col = column_of(expr)?;
            let (lo, hi) = (constant(low)?, constant(high)?);
            if lo.is_null() || hi.is_null() {
                return Some((col, P::Never));
            }
            Some((
                col,
                P::Range {
                    lo: bound(lo, true),
                    hi: bound(hi, true),
                },
            ))
        }
        Expr::InList {
            expr,
            list,
            negated: false,
        } => {
            let col = column_of(expr)?;
            let mut values = Vec::with_capacity(list.len());
            for item in list {
                let v = constant(item)?;
                if !v.is_null() && !values.contains(&v) {
                    values.push(v);
                }
            }
            if values.is_empty() {
                return Some((col, P::Never));
            }
            Some((col, P::In(values)))
        }
        Expr::IsNull { expr, negated } => {
            let col = column_of(expr)?;
            Some((col, if *negated { P::IsNotNull } else { P::IsNull }))
        }
        _ => None,
    }
}

fn cmp(a: &Value, b: &Value) -> Option<Ordering> {
    a.compare(b).ok()
}

/// Tightest lower bound of two.
fn max_lo(a: Option<Bound>, b: Option<Bound>) -> Option<Bound> {
    match (a, b) {
        (None, x) | (x, None) => x,
        (Some(a), Some(b)) => match cmp(&a.value, &b.value) {
            Some(Ordering::Less) => Some(b),
            Some(Ordering::Greater) | None => Some(a),
            Some(Ordering::Equal) => Some(if a.inclusive { b } else { a }),
        },
    }
}

/// Tightest upper bound of two.
fn min_hi(a: Option<Bound>, b: Option<Bound>) -> Option<Bound> {
    match (a, b) {
        (None, x) | (x, None) => x,
        (Some(a), Some(b)) => match cmp(&a.value, &b.value) {
            Some(Ordering::Greater) => Some(b),
            Some(Ordering::Less) | None => Some(a),
            Some(Ordering::Equal) => Some(if a.inclusive { b } else { a }),
        },
    }
}

/// Position of a value on a numeric axis (numeric and temporal types).
fn axis(v: &Value) -> Option<f64> {
    match v {
        Value::Int(i) => Some(*i as f64),
        Value::Float(f) => Some(*f),
        Value::Decimal(u, s) => Some(decimal::to_f64(*u, *s)),
        Value::Date(d) => Some(*d as f64),
        Value::Timestamp(t) => Some(*t as f64),
        _ => None,
    }
}

/// Estimated fraction of rows satisfying `pred` (indexes-and-planning.md §3:
/// equality ≈ 1/distinct, ranges by linear interpolation between min and max
/// for numeric/temporal types, 1/3 otherwise).
pub fn selectivity(pred: &ColumnPredicate, stats: &ColumnStats, rows: usize) -> f64 {
    use ColumnPredicate as P;
    let distinct = stats.distinct_count.max(1) as f64;
    let rows_f = rows.max(1) as f64;
    match pred {
        P::Never => 0.0,
        P::Eq(_) => 1.0 / distinct,
        P::In(vs) => (vs.len() as f64 / distinct).min(1.0),
        P::Ne(_) => 1.0 - 1.0 / distinct,
        P::IsNull => stats.null_count as f64 / rows_f,
        P::IsNotNull => 1.0 - stats.null_count as f64 / rows_f,
        P::Range { lo, hi } => {
            let (Some(min), Some(max)) = (&stats.min, &stats.max) else {
                return 0.0; // no non-null values
            };
            let (Some(mn), Some(mx)) = (axis(min), axis(max)) else {
                return DEFAULT_SELECTIVITY;
            };
            let l = match lo {
                None => mn,
                Some(b) => match axis(&b.value) {
                    Some(x) => x.max(mn),
                    None => return DEFAULT_SELECTIVITY,
                },
            };
            let h = match hi {
                None => mx,
                Some(b) => match axis(&b.value) {
                    Some(x) => x.min(mx),
                    None => return DEFAULT_SELECTIVITY,
                },
            };
            if h < l {
                return 0.0;
            }
            if mx <= mn {
                return 1.0; // single value inside the range
            }
            ((h - l) / (mx - mn)).clamp(0.0, 1.0)
        }
    }
}

/// How an index scan finds its rows.
#[derive(Debug, Clone, PartialEq)]
pub enum IndexLookup {
    /// Rows equal to any of the values.
    Eq(Vec<Value>),
    Range {
        lo: Option<Bound>,
        hi: Option<Bound>,
    },
}

impl fmt::Display for IndexLookup {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = |v: &Value| match v {
            Value::Str(s) => format!("'{}'", s.replace('\'', "''")),
            v => v.to_text(),
        };
        match self {
            IndexLookup::Eq(vs) if vs.len() == 1 => write!(f, "= {}", text(&vs[0])),
            IndexLookup::Eq(vs) => write!(
                f,
                "IN ({})",
                vs.iter().map(text).collect::<Vec<_>>().join(", ")
            ),
            IndexLookup::Range { lo, hi } => {
                let mut parts = Vec::new();
                if let Some(b) = lo {
                    parts.push(format!(
                        "{} {}",
                        if b.inclusive { ">=" } else { ">" },
                        text(&b.value)
                    ));
                }
                if let Some(b) = hi {
                    parts.push(format!(
                        "{} {}",
                        if b.inclusive { "<=" } else { "<" },
                        text(&b.value)
                    ));
                }
                f.write_str(&parts.join(" AND "))
            }
        }
    }
}

impl IndexLookup {
    /// Row ids (ascending) matched by this lookup.
    pub fn run(&self, index: &Index) -> Vec<u32> {
        match self {
            IndexLookup::Eq(vs) => index.lookup_eq(vs),
            IndexLookup::Range { lo, hi } => index.lookup_range(lo.as_ref(), hi.as_ref()),
        }
    }
}

/// True if a value has the same runtime representation family as the column
/// type, so that hash lookups agree with SQL equality.
fn same_family(ty: DataType, v: &Value) -> bool {
    matches!(
        (ty, v),
        (DataType::Boolean, Value::Bool(_))
            | (DataType::Int64, Value::Int(_))
            | (DataType::Float64, Value::Float(_))
            | (DataType::Decimal { .. }, Value::Decimal(..))
            | (DataType::String, Value::Str(_))
            | (DataType::Date, Value::Date(_))
            | (DataType::Timestamp, Value::Timestamp(_))
    )
}

/// The chosen index access of a filtered scan.
#[derive(Debug, Clone)]
pub struct IndexChoice {
    pub index: Arc<Index>,
    pub lookup: IndexLookup,
    /// Conjuncts (positions in the input list) answered exactly by the lookup.
    pub used: Vec<usize>,
    pub selectivity: f64,
}

/// Picks the most selective usable index for `conjuncts` over a scan of
/// `table` producing table columns `columns` (in scan output order), if it
/// is selective enough.
pub fn choose_index(
    table: &Table,
    columns: &[usize],
    indexes: &[Arc<Index>],
    conjuncts: &[Expr],
) -> Option<IndexChoice> {
    if indexes.is_empty() {
        return None;
    }
    let analyzed: Vec<Option<(usize, ColumnPredicate)>> = conjuncts
        .iter()
        .map(|c| analyze(c).map(|(col, p)| (columns[col], p)))
        .collect();
    let mut best: Option<IndexChoice> = None;
    for ix in indexes {
        let ty = table.fields[ix.column].data_type;
        let Ok(stats) = table.column_stats(ix.column) else {
            continue;
        };
        let mut candidates: Vec<(IndexLookup, Vec<usize>, f64)> = Vec::new();
        // Equality-style conjuncts: each one alone.
        for (i, a) in analyzed.iter().enumerate() {
            let Some((col, pred)) = a else { continue };
            if *col != ix.column {
                continue;
            }
            let values = match pred {
                ColumnPredicate::Never => Vec::new(),
                ColumnPredicate::Eq(v) => vec![v.clone()],
                ColumnPredicate::In(vs) => vs.clone(),
                _ => continue,
            };
            if ix.kind == IndexKind::Hash && !values.iter().all(|v| same_family(ty, v)) {
                continue;
            }
            let sel = selectivity(pred, &stats, table.row_count);
            candidates.push((IndexLookup::Eq(values), vec![i], sel));
        }
        // All range conjuncts on the column, intersected.
        if ix.supports_range() {
            let (mut lo, mut hi, mut used) = (None, None, Vec::new());
            for (i, a) in analyzed.iter().enumerate() {
                if let Some((col, ColumnPredicate::Range { lo: l, hi: h })) = a
                    && *col == ix.column
                {
                    lo = max_lo(lo, l.clone());
                    hi = min_hi(hi, h.clone());
                    used.push(i);
                }
            }
            if !used.is_empty() {
                let pred = ColumnPredicate::Range {
                    lo: lo.clone(),
                    hi: hi.clone(),
                };
                let sel = selectivity(&pred, &stats, table.row_count);
                candidates.push((IndexLookup::Range { lo, hi }, used, sel));
            }
        }
        for (lookup, used, sel) in candidates {
            let better = best.as_ref().is_none_or(|b| {
                sel < b.selectivity
                    || (sel == b.selectivity
                        && ix.kind == IndexKind::Hash
                        && b.index.kind == IndexKind::Btree)
            });
            if better {
                best = Some(IndexChoice {
                    index: ix.clone(),
                    lookup,
                    used,
                    selectivity: sel,
                });
            }
        }
    }
    best.filter(|b| {
        b.selectivity <= INDEX_SELECTIVITY
            || b.selectivity * table.row_count as f64 <= INDEX_MAX_TINY_ROWS
    })
}

/// True if no row of a chunk with statistics `zone` (and `len` rows) can
/// satisfy `pred`.
pub fn zone_excludes(pred: &ColumnPredicate, zone: &Zone, len: usize) -> bool {
    use ColumnPredicate as P;
    let all_null = zone.null_count == Some(len);
    match pred {
        P::Never => true,
        P::IsNull => zone.null_count == Some(0),
        P::IsNotNull => all_null,
        _ if all_null => true,
        _ => {
            let (Some(min), Some(max)) = (&zone.min, &zone.max) else {
                return false;
            };
            let outside = |v: &Value| {
                matches!(cmp(v, min), Some(Ordering::Less))
                    || matches!(cmp(v, max), Some(Ordering::Greater))
            };
            match pred {
                P::Eq(v) => outside(v),
                P::In(vs) => vs.iter().all(outside),
                P::Ne(v) => {
                    matches!(cmp(min, v), Some(Ordering::Equal))
                        && matches!(cmp(max, v), Some(Ordering::Equal))
                }
                P::Range { lo, hi } => {
                    let below = lo.as_ref().is_some_and(|b| match cmp(max, &b.value) {
                        Some(Ordering::Less) => true,
                        Some(Ordering::Equal) => !b.inclusive,
                        _ => false,
                    });
                    let above = hi.as_ref().is_some_and(|b| match cmp(min, &b.value) {
                        Some(Ordering::Greater) => true,
                        Some(Ordering::Equal) => !b.inclusive,
                        _ => false,
                    });
                    below || above
                }
                _ => false,
            }
        }
    }
}

/// Row groups of `table` that may contain rows satisfying all `conjuncts`
/// (over scan output columns mapped to table columns by `columns`).
pub fn select_row_groups(table: &Table, columns: &[usize], conjuncts: &[Expr]) -> Vec<usize> {
    let preds: Vec<(usize, ColumnPredicate)> = conjuncts
        .iter()
        .filter_map(analyze)
        .map(|(col, p)| (columns[col], p))
        .collect();
    table
        .row_groups()
        .iter()
        .enumerate()
        .filter(|(_, g)| {
            g.zones.is_empty()
                || !preds
                    .iter()
                    .any(|(col, p)| zone_excludes(p, &g.zones[*col], g.len))
        })
        .map(|(i, _)| i)
        .collect()
}

/// Estimated fraction of `table` rows passing all `conjuncts`.
pub fn filter_selectivity(table: &Table, columns: &[usize], conjuncts: &[Expr]) -> f64 {
    conjuncts
        .iter()
        .map(|c| match analyze(c) {
            Some((col, p)) => match table.column_stats(columns[col]) {
                Ok(stats) => selectivity(&p, &stats, table.row_count),
                Err(_) => DEFAULT_SELECTIVITY,
            },
            None => DEFAULT_SELECTIVITY,
        })
        .product()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn col(i: usize) -> Box<Expr> {
        Box::new(Expr::Column {
            index: i,
            ty: DataType::Int64,
        })
    }

    fn lit(v: i64) -> Box<Expr> {
        Box::new(Expr::Literal {
            value: Value::Int(v),
            ty: DataType::Int64,
        })
    }

    #[test]
    fn recognizes_flipped_comparison() {
        let e = Expr::Compare {
            op: BinaryOp::Lt,
            left: lit(5),
            right: col(2),
        };
        assert_eq!(
            analyze(&e),
            Some((
                2,
                ColumnPredicate::Range {
                    lo: bound(Value::Int(5), false),
                    hi: None
                }
            ))
        );
    }

    #[test]
    fn range_selectivity_interpolates() {
        let stats = ColumnStats {
            null_count: 0,
            distinct_count: 100,
            min: Some(Value::Int(0)),
            max: Some(Value::Int(100)),
        };
        let p = ColumnPredicate::Range {
            lo: bound(Value::Int(90), true),
            hi: None,
        };
        assert!((selectivity(&p, &stats, 100) - 0.1).abs() < 1e-9);
        assert_eq!(
            selectivity(&ColumnPredicate::Eq(Value::Int(1)), &stats, 100),
            0.01
        );
    }

    #[test]
    fn zone_skipping() {
        let zone = Zone {
            null_count: Some(0),
            min: Some(Value::Int(10)),
            max: Some(Value::Int(20)),
        };
        let gt = |v, inclusive| ColumnPredicate::Range {
            lo: bound(Value::Int(v), inclusive),
            hi: None,
        };
        assert!(zone_excludes(&gt(20, false), &zone, 5));
        assert!(!zone_excludes(&gt(20, true), &zone, 5));
        assert!(zone_excludes(&ColumnPredicate::Eq(Value::Int(9)), &zone, 5));
        assert!(!zone_excludes(
            &ColumnPredicate::Eq(Value::Int(15)),
            &zone,
            5
        ));
        assert!(zone_excludes(&ColumnPredicate::IsNull, &zone, 5));
    }
}
