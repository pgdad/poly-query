//! Column vectors and batches: the data unit of vectorized execution.
//!
//! A [`Vector`] holds the values of one column for the rows of a batch in a
//! typed, contiguous array (plus an optional validity array), so kernels run
//! tight, branch-light loops the compiler can auto-vectorize. Dictionary
//! encoded strings stay encoded (codes + shared dictionary). Values whose
//! runtime representation is not uniform (e.g. DECIMALs of mixed scales) use
//! the generic `Values` representation, which every kernel accepts through a
//! value-at-a-time fallback. `Data::Decimal` only holds values of at most 18
//! digits; wide (128-bit) decimals use `Values`.

use std::sync::Arc;

use crate::exec::Row;
use crate::storage::{Column, ColumnData};
use crate::types::{DataType, Value, datetime, decimal};

/// Rows per batch produced by scans.
pub const BATCH_SIZE: usize = 2048;

/// Marker for "no row" in gather index lists (produces NULL).
pub const NO_ROW: u32 = u32::MAX;

#[derive(Debug, Clone)]
pub enum Data {
    /// Every value is NULL.
    Null,
    Bool(Vec<bool>),
    Int(Vec<i64>),
    Float(Vec<f64>),
    /// Unscaled values with one scale for the whole vector; every value has
    /// at most 18 digits (wider values use `Values`).
    Decimal(Vec<i64>, u8),
    Str(Vec<Arc<str>>),
    /// Dictionary-encoded strings: codes into a shared dictionary.
    Dict(Vec<u32>, Arc<[Arc<str>]>),
    Date(Vec<i32>),
    Timestamp(Vec<i64>),
    /// Generic representation (may contain `Value::Null`).
    Values(Vec<Value>),
}

#[derive(Debug, Clone)]
pub struct Vector {
    pub data: Data,
    /// Validity of typed data (true = non-null); None = no NULLs. Not used
    /// by `Null` and `Values`.
    pub valid: Option<Vec<bool>>,
    len: usize,
}

fn gather_slice<T: Clone>(v: &[T], idx: &[u32]) -> Vec<T> {
    idx.iter().map(|&i| v[i as usize].clone()).collect()
}

/// Gathers with `NO_ROW` entries taking `default`.
fn gather_slice_opt<T: Clone>(v: &[T], idx: &[u32], default: T) -> Vec<T> {
    idx.iter()
        .map(|&i| {
            if i == NO_ROW {
                default.clone()
            } else {
                v[i as usize].clone()
            }
        })
        .collect()
}

impl Vector {
    /// A typed vector (`data` must not be `Null`).
    pub fn new(data: Data, valid: Option<Vec<bool>>) -> Vector {
        let len = match &data {
            Data::Null => 0,
            Data::Bool(v) => v.len(),
            Data::Int(v) | Data::Timestamp(v) | Data::Decimal(v, _) => v.len(),
            Data::Float(v) => v.len(),
            Data::Str(v) => v.len(),
            Data::Dict(c, _) => c.len(),
            Data::Date(v) => v.len(),
            Data::Values(v) => v.len(),
        };
        debug_assert!(!matches!(data, Data::Null));
        debug_assert!(valid.as_ref().is_none_or(|v| v.len() == len));
        let valid = match data {
            Data::Values(_) => None,
            _ => valid,
        };
        Vector { data, valid, len }
    }

    /// `len` NULLs.
    pub fn null(len: usize) -> Vector {
        Vector {
            data: Data::Null,
            valid: None,
            len,
        }
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// `len` copies of `v`.
    pub fn broadcast(v: &Value, len: usize) -> Vector {
        match v {
            Value::Null => Vector::null(len),
            Value::Bool(b) => Vector::new(Data::Bool(vec![*b; len]), None),
            Value::Int(i) => Vector::new(Data::Int(vec![*i; len]), None),
            Value::Float(f) => Vector::new(Data::Float(vec![*f; len]), None),
            Value::Decimal(u, s) if decimal::fits18(*u) => {
                Vector::new(Data::Decimal(vec![*u as i64; len], *s), None)
            }
            Value::Decimal(..) => Vector::new(Data::Values(vec![v.clone(); len]), None),
            Value::Str(s) => {
                Vector::new(Data::Dict(vec![0; len], Arc::from(vec![s.clone()])), None)
            }
            Value::Date(d) => Vector::new(Data::Date(vec![*d; len]), None),
            Value::Timestamp(t) => Vector::new(Data::Timestamp(vec![*t; len]), None),
        }
    }

    /// Builds a vector from values, using a typed representation when all
    /// non-NULL values share one.
    pub fn from_values(values: Vec<Value>) -> Vector {
        let len = values.len();
        let Some(first) = values.iter().find(|v| !v.is_null()) else {
            return Vector::null(len);
        };
        let uniform = values.iter().all(|v| match (first, v) {
            (_, Value::Null) => true,
            (Value::Decimal(_, a), Value::Decimal(u, b)) => a == b && decimal::fits18(*u),
            _ => std::mem::discriminant(first) == std::mem::discriminant(v),
        });
        if !uniform {
            return Vector::new(Data::Values(values), None);
        }
        let has_null = values.iter().any(Value::is_null);
        let valid = has_null.then(|| values.iter().map(|v| !v.is_null()).collect());
        macro_rules! typed {
            ($variant:ident, $pat:pat => $e:expr, $default:expr) => {
                Data::$variant(
                    values
                        .into_iter()
                        .map(|v| match v {
                            $pat => $e,
                            _ => $default,
                        })
                        .collect(),
                )
            };
        }
        let data = match first {
            Value::Bool(_) => typed!(Bool, Value::Bool(b) => b, false),
            Value::Int(_) => typed!(Int, Value::Int(i) => i, 0),
            Value::Float(_) => typed!(Float, Value::Float(f) => f, 0.0),
            Value::Decimal(_, s) => {
                let s = *s;
                Data::Decimal(
                    values
                        .into_iter()
                        .map(|v| match v {
                            Value::Decimal(u, _) => u as i64,
                            _ => 0,
                        })
                        .collect(),
                    s,
                )
            }
            Value::Str(_) => {
                let empty: Arc<str> = Arc::from("");
                Data::Str(
                    values
                        .into_iter()
                        .map(|v| match v {
                            Value::Str(s) => s,
                            _ => empty.clone(),
                        })
                        .collect(),
                )
            }
            Value::Date(_) => typed!(Date, Value::Date(d) => d, 0),
            Value::Timestamp(_) => typed!(Timestamp, Value::Timestamp(t) => t, 0),
            Value::Null => unreachable!(),
        };
        Vector::new(data, valid)
    }

    /// Rows `[from, to)` of a stored column.
    pub fn from_column(col: &Column, from: usize, to: usize) -> Vector {
        let valid = col.validity.range_bools(from, to);
        let data = match &col.data {
            ColumnData::Boolean(v) => Data::Bool(v[from..to].to_vec()),
            ColumnData::Int64(v) => Data::Int(v[from..to].to_vec()),
            ColumnData::Float64(v) => Data::Float(v[from..to].to_vec()),
            ColumnData::Decimal(v) => Data::Decimal(v[from..to].to_vec(), col.decimal_scale()),
            ColumnData::WideDecimal(v) => {
                let scale = col.decimal_scale();
                Data::Values(
                    (from..to)
                        .map(|i| {
                            if col.validity.get(i) {
                                Value::Decimal(v[i], scale)
                            } else {
                                Value::Null
                            }
                        })
                        .collect(),
                )
            }
            ColumnData::String(v) => Data::Str(v[from..to].to_vec()),
            ColumnData::Dict { codes, dict } => Data::Dict(codes[from..to].to_vec(), dict.clone()),
            ColumnData::Date(v) => Data::Date(v[from..to].to_vec()),
            ColumnData::Timestamp(v) => Data::Timestamp(v[from..to].to_vec()),
        };
        Vector::new(data, valid)
    }

    #[inline]
    pub fn is_null(&self, i: usize) -> bool {
        match &self.data {
            Data::Null => true,
            Data::Values(v) => v[i].is_null(),
            _ => self.valid.as_ref().is_some_and(|v| !v[i]),
        }
    }

    /// True if no element is NULL.
    pub fn no_nulls(&self) -> bool {
        match &self.data {
            Data::Null => self.len == 0,
            Data::Values(v) => !v.iter().any(Value::is_null),
            _ => self.valid.as_ref().is_none_or(|v| v.iter().all(|&b| b)),
        }
    }

    /// Validity of element `i` as a function-friendly flag array (None = all valid).
    pub fn validity(&self) -> Option<Vec<bool>> {
        match &self.data {
            Data::Null => Some(vec![false; self.len]),
            Data::Values(v) => Some(v.iter().map(|x| !x.is_null()).collect()),
            _ => self.valid.clone(),
        }
    }

    /// The value at `i`.
    pub fn value(&self, i: usize) -> Value {
        if self.is_null(i) {
            return Value::Null;
        }
        match &self.data {
            Data::Null => Value::Null,
            Data::Bool(v) => Value::Bool(v[i]),
            Data::Int(v) => Value::Int(v[i]),
            Data::Float(v) => Value::Float(v[i]),
            Data::Decimal(v, s) => Value::Decimal(v[i] as i128, *s),
            Data::Str(v) => Value::Str(v[i].clone()),
            Data::Dict(c, d) => Value::Str(d[c[i] as usize].clone()),
            Data::Date(v) => Value::Date(v[i]),
            Data::Timestamp(v) => Value::Timestamp(v[i]),
            Data::Values(v) => v[i].clone(),
        }
    }

    /// Serializes element `i` like `Value::write_json` (types.md §9);
    /// `ty` is the column type.
    pub fn write_json(&self, i: usize, ty: DataType, out: &mut String) {
        if self.is_null(i) {
            out.push_str("null");
            return;
        }
        match &self.data {
            Data::Int(v) => decimal::write_i64(out, v[i]),
            Data::Str(v) => crate::json::write_escaped(out, &v[i]),
            Data::Dict(c, d) => crate::json::write_escaped(out, &d[c[i] as usize]),
            Data::Decimal(v, s) if !matches!(ty, DataType::Decimal { scale, .. } if scale != *s) => {
                out.push('"');
                decimal::write(out, v[i] as i128, *s);
                out.push('"');
            }
            Data::Date(v) => {
                out.push('"');
                datetime::write_date(out, v[i]);
                out.push('"');
            }
            Data::Timestamp(v) => {
                out.push('"');
                datetime::write_timestamp(out, v[i]);
                out.push('"');
            }
            _ => self.value(i).write_json(ty, out),
        }
    }

    /// The string at `i` (None for NULL or a non-string vector).
    #[inline]
    pub fn str_at(&self, i: usize) -> Option<&str> {
        if self.is_null(i) {
            return None;
        }
        match &self.data {
            Data::Str(v) => Some(&v[i]),
            Data::Dict(c, d) => Some(&d[c[i] as usize]),
            Data::Values(v) => match &v[i] {
                Value::Str(s) => Some(s),
                _ => None,
            },
            _ => None,
        }
    }

    /// Elements at positions `idx` (in that order).
    pub fn gather(&self, idx: &[u32]) -> Vector {
        let valid = self.valid.as_ref().map(|v| gather_slice(v, idx));
        let data = match &self.data {
            Data::Null => return Vector::null(idx.len()),
            Data::Bool(v) => Data::Bool(gather_slice(v, idx)),
            Data::Int(v) => Data::Int(gather_slice(v, idx)),
            Data::Float(v) => Data::Float(gather_slice(v, idx)),
            Data::Decimal(v, s) => Data::Decimal(gather_slice(v, idx), *s),
            Data::Str(v) => Data::Str(gather_slice(v, idx)),
            Data::Dict(c, d) => Data::Dict(gather_slice(c, idx), d.clone()),
            Data::Date(v) => Data::Date(gather_slice(v, idx)),
            Data::Timestamp(v) => Data::Timestamp(gather_slice(v, idx)),
            Data::Values(v) => Data::Values(gather_slice(v, idx)),
        };
        Vector::new(data, valid)
    }

    /// Like [`Vector::gather`], but `NO_ROW` positions become NULL.
    pub fn gather_opt(&self, idx: &[u32]) -> Vector {
        if !idx.contains(&NO_ROW) {
            return self.gather(idx);
        }
        let valid: Vec<bool> = match &self.valid {
            Some(v) => idx.iter().map(|&i| i != NO_ROW && v[i as usize]).collect(),
            None => idx.iter().map(|&i| i != NO_ROW).collect(),
        };
        let data = match &self.data {
            Data::Null => return Vector::null(idx.len()),
            Data::Bool(v) => Data::Bool(gather_slice_opt(v, idx, false)),
            Data::Int(v) => Data::Int(gather_slice_opt(v, idx, 0)),
            Data::Float(v) => Data::Float(gather_slice_opt(v, idx, 0.0)),
            Data::Decimal(v, s) => Data::Decimal(gather_slice_opt(v, idx, 0), *s),
            Data::Str(v) => Data::Str(gather_slice_opt(v, idx, Arc::from(""))),
            Data::Dict(c, d) => Data::Dict(gather_slice_opt(c, idx, 0), d.clone()),
            Data::Date(v) => Data::Date(gather_slice_opt(v, idx, 0)),
            Data::Timestamp(v) => Data::Timestamp(gather_slice_opt(v, idx, 0)),
            Data::Values(v) => {
                return Vector::new(Data::Values(gather_slice_opt(v, idx, Value::Null)), None);
            }
        };
        Vector::new(data, Some(valid))
    }

    /// A plain string vector as a dictionary-encoded one whose dictionary
    /// is the vector's own strings (codes are row numbers), so that gathers
    /// copy codes instead of string references. Other vectors unchanged.
    pub fn into_dictionary(self) -> Vector {
        match self.data {
            Data::Str(v) => Vector::new(
                Data::Dict((0..v.len() as u32).collect(), Arc::from(v)),
                self.valid,
            ),
            data => Vector { data, ..self },
        }
    }

    /// Concatenates vectors, keeping a typed representation when possible.
    /// Takes the parts by value, so their data is moved, not cloned.
    pub fn concat(mut parts: Vec<Vector>) -> Vector {
        let len: usize = parts.iter().map(Vector::len).sum();
        let Some(first) = parts
            .iter()
            .find(|p| !matches!(p.data, Data::Null) && p.len > 0)
        else {
            return Vector::null(len);
        };
        if parts.len() == 1 {
            return parts.pop().unwrap_or_else(|| Vector::null(0));
        }
        // All parts (ignoring all-NULL ones) of one typed kind?
        let same = parts
            .iter()
            .filter(|p| !matches!(p.data, Data::Null) && p.len > 0)
            .all(|p| match (&first.data, &p.data) {
                (Data::Decimal(_, a), Data::Decimal(_, b)) => a == b,
                (Data::Dict(_, a), Data::Dict(_, b)) => Arc::ptr_eq(a, b),
                (Data::Values(_), _) | (_, Data::Values(_)) => false,
                (a, b) => std::mem::discriminant(a) == std::mem::discriminant(b),
            });
        if !same {
            let mut values = Vec::with_capacity(len);
            for p in &parts {
                values.extend((0..p.len).map(|i| p.value(i)));
            }
            return Vector::from_values(values);
        }
        let any_null = parts.iter().any(|p| !p.no_nulls());
        let valid = any_null.then(|| {
            let mut v = Vec::with_capacity(len);
            for p in &parts {
                match p.validity() {
                    Some(pv) => v.extend(pv),
                    None => v.extend(std::iter::repeat_n(true, p.len)),
                }
            }
            v
        });
        // The kind of the result (an empty vector of the parts' variant).
        let template = match &first.data {
            Data::Bool(_) => Data::Bool(Vec::new()),
            Data::Int(_) => Data::Int(Vec::new()),
            Data::Float(_) => Data::Float(Vec::new()),
            Data::Date(_) => Data::Date(Vec::new()),
            Data::Timestamp(_) => Data::Timestamp(Vec::new()),
            Data::Str(_) => Data::Str(Vec::new()),
            Data::Decimal(_, s) => Data::Decimal(Vec::new(), *s),
            Data::Dict(_, d) => Data::Dict(Vec::new(), d.clone()),
            Data::Null | Data::Values(_) => unreachable!(),
        };
        macro_rules! cat {
            ($variant:ident, $default:expr) => {{
                let mut out = Vec::with_capacity(len);
                for p in parts {
                    let n = p.len;
                    match p.data {
                        Data::$variant(v) => out.extend(v),
                        _ => out.extend(std::iter::repeat_n($default, n)),
                    }
                }
                out
            }};
        }
        let data = match template {
            Data::Bool(_) => Data::Bool(cat!(Bool, false)),
            Data::Int(_) => Data::Int(cat!(Int, 0)),
            Data::Float(_) => Data::Float(cat!(Float, 0.0)),
            Data::Date(_) => Data::Date(cat!(Date, 0)),
            Data::Timestamp(_) => Data::Timestamp(cat!(Timestamp, 0)),
            Data::Str(_) => {
                let empty: Arc<str> = Arc::from("");
                Data::Str(cat!(Str, empty.clone()))
            }
            Data::Decimal(_, s) => {
                let mut out = Vec::with_capacity(len);
                for p in parts {
                    let n = p.len;
                    match p.data {
                        Data::Decimal(v, _) => out.extend(v),
                        _ => out.extend(std::iter::repeat_n(0, n)),
                    }
                }
                Data::Decimal(out, s)
            }
            Data::Dict(_, d) => {
                let mut out = Vec::with_capacity(len);
                for p in parts {
                    let n = p.len;
                    match p.data {
                        Data::Dict(c, _) => out.extend(c),
                        _ => out.extend(std::iter::repeat_n(0, n)),
                    }
                }
                Data::Dict(out, d)
            }
            Data::Null | Data::Values(_) => unreachable!(),
        };
        Vector::new(data, valid)
    }

    /// Approximate retained size in bytes (memory accounting).
    pub fn approx_size(&self) -> usize {
        let per = match &self.data {
            Data::Null => 0,
            Data::Bool(_) => 1,
            Data::Int(_) | Data::Float(_) | Data::Decimal(..) | Data::Timestamp(_) => 8,
            Data::Date(_) | Data::Dict(..) => 4,
            Data::Str(v) => return v.iter().map(|s| 16 + s.len()).sum::<usize>() + self.len,
            Data::Values(v) => return v.iter().map(Value::approx_size).sum(),
        };
        self.len * (per + usize::from(self.valid.is_some()))
    }
}

/// A set of equally long column vectors (one per output column). `len` is
/// kept separately so that batches without columns (e.g. `COUNT(*)` inputs)
/// still carry their row count.
#[derive(Debug, Clone)]
pub struct Batch {
    pub columns: Vec<Vector>,
    pub len: usize,
}

impl Batch {
    pub fn new(columns: Vec<Vector>, len: usize) -> Batch {
        debug_assert!(columns.iter().all(|c| c.len() == len));
        Batch { columns, len }
    }

    pub fn width(&self) -> usize {
        self.columns.len()
    }

    pub fn gather(&self, idx: &[u32]) -> Batch {
        Batch::new(
            self.columns.iter().map(|c| c.gather(idx)).collect(),
            idx.len(),
        )
    }

    /// Rows where `mask` is true.
    pub fn filter(&self, mask: &[bool]) -> Batch {
        let idx = selection(mask);
        if idx.len() == self.len {
            return self.clone();
        }
        self.gather(&idx)
    }

    pub fn slice(&self, from: usize, to: usize) -> Batch {
        let idx: Vec<u32> = (from as u32..to as u32).collect();
        self.gather(&idx)
    }

    pub fn row(&self, i: usize) -> Row {
        self.columns.iter().map(|c| c.value(i)).collect()
    }

    pub fn into_rows(self) -> Vec<Row> {
        let mut rows: Vec<Row> = (0..self.len)
            .map(|_| Vec::with_capacity(self.columns.len()))
            .collect();
        for c in &self.columns {
            for (i, row) in rows.iter_mut().enumerate() {
                row.push(c.value(i));
            }
        }
        rows
    }

    pub fn from_rows(rows: &[Row], width: usize) -> Batch {
        let columns = (0..width)
            .map(|c| Vector::from_values(rows.iter().map(|r| r[c].clone()).collect()))
            .collect();
        Batch::new(columns, rows.len())
    }

    /// Concatenates batches of the same width (moving their data).
    pub fn concat(mut batches: Vec<Batch>, width: usize) -> Batch {
        if batches.len() == 1 {
            return batches.pop().unwrap_or_else(|| Batch::new(Vec::new(), 0));
        }
        let len = batches.iter().map(|b| b.len).sum();
        let mut parts: Vec<Vec<Vector>> = (0..width)
            .map(|_| Vec::with_capacity(batches.len()))
            .collect();
        for b in batches {
            for (c, v) in b.columns.into_iter().enumerate() {
                parts[c].push(v);
            }
        }
        let columns = parts.into_iter().map(Vector::concat).collect();
        Batch::new(columns, len)
    }

    pub fn approx_size(&self) -> usize {
        self.columns.iter().map(Vector::approx_size).sum::<usize>() + 64
    }
}

/// Positions of the true entries of `mask`.
pub fn selection(mask: &[bool]) -> Vec<u32> {
    let mut idx = Vec::with_capacity(mask.len());
    for (i, &m) in mask.iter().enumerate() {
        if m {
            idx.push(i as u32);
        }
    }
    idx
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typed_from_values_and_back() {
        let v = Vector::from_values(vec![Value::Int(1), Value::Null, Value::Int(3)]);
        assert!(matches!(v.data, Data::Int(_)));
        assert!(v.is_null(1));
        assert_eq!(v.value(2), Value::Int(3));
        let mixed = Vector::from_values(vec![Value::Decimal(1, 1), Value::Decimal(1, 2)]);
        assert!(matches!(mixed.data, Data::Values(_)));
        assert!(matches!(
            Vector::from_values(vec![Value::Null]).data,
            Data::Null
        ));
    }

    #[test]
    fn gather_and_concat() {
        let a = Vector::from_values(vec![Value::str("x"), Value::Null]);
        let b = Vector::from_values(vec![Value::str("y")]);
        let c = Vector::concat(vec![a, Vector::null(1), b]);
        assert_eq!(c.len(), 4);
        assert_eq!(c.value(3), Value::str("y"));
        assert!(c.is_null(2));
        let g = c.gather_opt(&[3, NO_ROW, 0]);
        assert_eq!(g.value(0), Value::str("y"));
        assert!(g.is_null(1));
        assert_eq!(g.value(2), Value::str("x"));
    }

    #[test]
    fn batch_rows_roundtrip() {
        let rows = vec![
            vec![Value::Int(1), Value::str("a")],
            vec![Value::Null, Value::str("b")],
        ];
        let b = Batch::from_rows(&rows, 2);
        assert_eq!(b.clone().into_rows(), rows);
        assert_eq!(b.filter(&[false, true]).row(0), rows[1]);
    }
}
