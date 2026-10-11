//! Typed column vectors with a validity (non-null) bitmap, including the
//! dictionary-encoded representation of STRING columns.

use std::collections::HashMap;
use std::sync::Arc;

use crate::types::{DataType, Value};

/// Packed bitmap, LSB-first within 64-bit words; bit set = value present
/// (non-null).
#[derive(Debug, Clone, Default)]
pub struct Bitmap {
    words: Vec<u64>,
    len: usize,
}

impl Bitmap {
    /// A bitmap of `len` set bits.
    pub fn all_set(len: usize) -> Self {
        let mut words = vec![u64::MAX; len.div_ceil(64)];
        if !len.is_multiple_of(64)
            && let Some(last) = words.last_mut()
        {
            *last = (1u64 << (len % 64)) - 1;
        }
        Bitmap { words, len }
    }

    /// Reads `len` bits from LSB-first bytes (bit `i` is bit `i % 8` of byte
    /// `i / 8`); bits beyond `len` are ignored. `bytes` must hold at least
    /// `ceil(len / 8)` bytes.
    pub fn from_lsb_bytes(bytes: &[u8], len: usize) -> Self {
        let mut words = vec![0u64; len.div_ceil(64)];
        for (i, &b) in bytes.iter().take(len.div_ceil(8)).enumerate() {
            words[i / 8] |= (b as u64) << ((i % 8) * 8);
        }
        if !len.is_multiple_of(64)
            && let Some(last) = words.last_mut()
        {
            *last &= (1u64 << (len % 64)) - 1;
        }
        Bitmap { words, len }
    }

    /// Writes bits `[start, start + n)` as LSB-first bytes (trailing bits 0).
    pub fn write_lsb_bytes(&self, start: usize, n: usize, out: &mut Vec<u8>) {
        let base = out.len();
        out.resize(base + n.div_ceil(8), 0);
        for i in 0..n {
            if self.get(start + i) {
                out[base + i / 8] |= 1 << (i % 8);
            }
        }
    }

    pub fn push(&mut self, bit: bool) {
        if self.len.is_multiple_of(64) {
            self.words.push(0);
        }
        if bit {
            self.words[self.len / 64] |= 1 << (self.len % 64);
        }
        self.len += 1;
    }

    pub fn get(&self, i: usize) -> bool {
        self.words[i / 64] & (1 << (i % 64)) != 0
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn count_ones(&self) -> usize {
        self.words.iter().map(|w| w.count_ones() as usize).sum()
    }

    /// Bits `[from, to)` as booleans, or None if they are all set (the
    /// common no-NULL case is detected word-wise without materializing).
    pub fn range_bools(&self, from: usize, to: usize) -> Option<Vec<bool>> {
        let mut all = true;
        let mut i = from;
        while i < to {
            let w = self.words[i / 64];
            let bit = i % 64;
            let n = (64 - bit).min(to - i);
            let mask = if n == 64 {
                u64::MAX
            } else {
                ((1u64 << n) - 1) << bit
            };
            if w & mask != mask {
                all = false;
                break;
            }
            i += n;
        }
        if all {
            return None;
        }
        Some((from..to).map(|i| self.get(i)).collect())
    }
}

/// Physical storage of one column's values. Slots of NULL entries hold a
/// default value and must be ignored.
#[derive(Debug, Clone)]
pub enum ColumnData {
    Boolean(Vec<bool>),
    Int64(Vec<i64>),
    Float64(Vec<f64>),
    /// Unscaled values; the scale comes from the column type.
    Decimal(Vec<i64>),
    String(Vec<Arc<str>>),
    /// Dictionary-encoded STRING: `codes[i]` indexes `dict` (codes of NULL
    /// slots are 0 and ignored).
    Dict {
        codes: Vec<u32>,
        dict: Arc<[Arc<str>]>,
    },
    Date(Vec<i32>),
    Timestamp(Vec<i64>),
}

/// An immutable typed column.
#[derive(Debug, Clone)]
pub struct Column {
    pub data_type: DataType,
    pub data: ColumnData,
    pub validity: Bitmap,
}

impl Column {
    pub fn len(&self) -> usize {
        self.validity.len()
    }

    pub fn is_empty(&self) -> bool {
        self.validity.is_empty()
    }

    pub fn null_count(&self) -> usize {
        self.len() - self.validity.count_ones()
    }

    pub fn is_null(&self, row: usize) -> bool {
        !self.validity.get(row)
    }

    pub fn is_dictionary(&self) -> bool {
        matches!(self.data, ColumnData::Dict { .. })
    }

    /// The value at `row` as a runtime value.
    pub fn value(&self, row: usize) -> Value {
        if !self.validity.get(row) {
            return Value::Null;
        }
        match &self.data {
            ColumnData::Boolean(v) => Value::Bool(v[row]),
            ColumnData::Int64(v) => Value::Int(v[row]),
            ColumnData::Float64(v) => Value::Float(v[row]),
            ColumnData::Decimal(v) => {
                let scale = match self.data_type {
                    DataType::Decimal { scale, .. } => scale,
                    _ => 0,
                };
                Value::Decimal(v[row], scale)
            }
            ColumnData::String(v) => Value::Str(v[row].clone()),
            ColumnData::Dict { codes, dict } => Value::Str(dict[codes[row] as usize].clone()),
            ColumnData::Date(v) => Value::Date(v[row]),
            ColumnData::Timestamp(v) => Value::Timestamp(v[row]),
        }
    }

    /// The string at `row` of a STRING column (None for NULL).
    pub fn str_at(&self, row: usize) -> Option<&str> {
        if !self.validity.get(row) {
            return None;
        }
        match &self.data {
            ColumnData::String(v) => Some(&v[row]),
            ColumnData::Dict { codes, dict } => Some(&dict[codes[row] as usize]),
            _ => None,
        }
    }

    /// Integer representation of a fixed-width non-null slot (BOOLEAN as
    /// 0/1, DATE days widened); None for FLOAT64 and STRING columns.
    pub fn int_repr(&self, row: usize) -> Option<i64> {
        match &self.data {
            ColumnData::Boolean(v) => Some(v[row] as i64),
            ColumnData::Int64(v) | ColumnData::Decimal(v) | ColumnData::Timestamp(v) => {
                Some(v[row])
            }
            ColumnData::Date(v) => Some(v[row] as i64),
            _ => None,
        }
    }

    /// Converts a plain STRING column to dictionary encoding (other columns
    /// are returned unchanged).
    pub fn into_dictionary(self) -> Column {
        let ColumnData::String(values) = self.data else {
            return self;
        };
        let mut lookup: HashMap<Arc<str>, u32> = HashMap::new();
        let mut dict = Vec::new();
        let mut codes = Vec::with_capacity(values.len());
        for (i, s) in values.into_iter().enumerate() {
            if !self.validity.get(i) {
                codes.push(0);
                continue;
            }
            let code = *lookup.entry(s.clone()).or_insert_with(|| {
                dict.push(s);
                (dict.len() - 1) as u32
            });
            codes.push(code);
        }
        Column {
            data_type: self.data_type,
            data: ColumnData::Dict {
                codes,
                dict: dict.into(),
            },
            validity: self.validity,
        }
    }

    /// Dictionary-encodes a STRING column if that saves space: at least 64
    /// rows and at most half as many distinct values as rows.
    pub fn maybe_dictionary(self) -> Column {
        let ColumnData::String(values) = &self.data else {
            return self;
        };
        if values.len() < 64 {
            return self;
        }
        let limit = values.len() / 2;
        let mut distinct = std::collections::HashSet::new();
        for (i, s) in values.iter().enumerate() {
            if self.validity.get(i) && distinct.insert(&**s) && distinct.len() > limit {
                return self;
            }
        }
        self.into_dictionary()
    }
}

/// Incrementally builds a column of a fixed type.
#[derive(Debug)]
pub struct ColumnBuilder {
    data_type: DataType,
    data: ColumnData,
    validity: Bitmap,
}

impl ColumnBuilder {
    pub fn new(data_type: DataType) -> Self {
        Self::with_capacity(data_type, 0)
    }

    pub fn with_capacity(data_type: DataType, n: usize) -> Self {
        let data = match data_type {
            DataType::Boolean => ColumnData::Boolean(Vec::with_capacity(n)),
            DataType::Int64 => ColumnData::Int64(Vec::with_capacity(n)),
            DataType::Float64 => ColumnData::Float64(Vec::with_capacity(n)),
            DataType::Decimal { .. } => ColumnData::Decimal(Vec::with_capacity(n)),
            DataType::String | DataType::Null => ColumnData::String(Vec::with_capacity(n)),
            DataType::Date => ColumnData::Date(Vec::with_capacity(n)),
            DataType::Timestamp => ColumnData::Timestamp(Vec::with_capacity(n)),
        };
        let data_type = data_type.result_type();
        ColumnBuilder {
            data_type,
            data,
            validity: Bitmap::default(),
        }
    }

    pub fn data_type(&self) -> DataType {
        self.data_type
    }

    pub fn push_null(&mut self) {
        self.validity.push(false);
        match &mut self.data {
            ColumnData::Boolean(v) => v.push(false),
            ColumnData::Int64(v) => v.push(0),
            ColumnData::Float64(v) => v.push(0.0),
            ColumnData::Decimal(v) => v.push(0),
            ColumnData::String(v) => v.push(Arc::from("")),
            ColumnData::Dict { codes, .. } => codes.push(0),
            ColumnData::Date(v) => v.push(0),
            ColumnData::Timestamp(v) => v.push(0),
        }
    }

    /// Appends a value whose runtime representation matches the column type
    /// (DECIMAL values must already carry the column's scale).
    pub fn push(&mut self, value: Value) {
        match (&mut self.data, value) {
            (_, Value::Null) => return self.push_null(),
            (ColumnData::Boolean(v), Value::Bool(b)) => v.push(b),
            (ColumnData::Int64(v), Value::Int(i)) => v.push(i),
            (ColumnData::Float64(v), Value::Float(f)) => v.push(f),
            (ColumnData::Decimal(v), Value::Decimal(u, _)) => v.push(u),
            (ColumnData::String(v), Value::Str(s)) => v.push(s),
            (ColumnData::Date(v), Value::Date(d)) => v.push(d),
            (ColumnData::Timestamp(v), Value::Timestamp(t)) => v.push(t),
            (data, value) => panic!("value {value:?} does not match column {data:?}"),
        }
        self.validity.push(true);
    }

    pub fn finish(self) -> Column {
        Column {
            data_type: self.data_type,
            data: self.data,
            validity: self.validity,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_and_read() {
        let mut b = ColumnBuilder::new(DataType::decimal(10, 2));
        b.push(Value::Decimal(150, 2));
        b.push_null();
        let c = b.finish();
        assert_eq!(c.len(), 2);
        assert_eq!(c.null_count(), 1);
        assert_eq!(c.value(0), Value::Decimal(150, 2));
        assert!(c.value(1).is_null());
    }

    #[test]
    fn bitmap_many() {
        let mut b = Bitmap::default();
        for i in 0..200 {
            b.push(i % 3 == 0);
        }
        assert_eq!(b.count_ones(), 67);
        assert!(b.get(198));
        assert!(!b.get(199));
        let mut bytes = Vec::new();
        b.write_lsb_bytes(0, 200, &mut bytes);
        assert_eq!(bytes.len(), 25);
        let back = Bitmap::from_lsb_bytes(&bytes, 200);
        assert_eq!(back.count_ones(), 67);
        assert!((0..200).all(|i| back.get(i) == b.get(i)));
        assert_eq!(Bitmap::all_set(70).count_ones(), 70);
    }

    #[test]
    fn bitmap_ignores_trailing_bits() {
        let b = Bitmap::from_lsb_bytes(&[0xFF], 3);
        assert_eq!(b.count_ones(), 3);
    }

    #[test]
    fn dictionary_encoding() {
        let mut b = ColumnBuilder::new(DataType::String);
        for s in ["a", "b", "a"] {
            b.push(Value::str(s));
        }
        b.push_null();
        let c = b.finish().into_dictionary();
        assert!(c.is_dictionary());
        assert_eq!(c.value(2), Value::str("a"));
        assert!(c.value(3).is_null());
        let ColumnData::Dict { dict, .. } = &c.data else {
            panic!()
        };
        assert_eq!(dict.len(), 2);
    }
}
