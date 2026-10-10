//! Typed column vectors with a validity (non-null) bitmap.

use std::sync::Arc;

use crate::types::{DataType, Value};

/// Packed bitmap; bit set = value present (non-null).
#[derive(Debug, Clone, Default)]
pub struct Bitmap {
    words: Vec<u64>,
    len: usize,
}

impl Bitmap {
    pub fn push(&mut self, bit: bool) {
        if self.len % 64 == 0 {
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
            ColumnData::Date(v) => Value::Date(v[row]),
            ColumnData::Timestamp(v) => Value::Timestamp(v[row]),
        }
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
        let data = match data_type {
            DataType::Boolean => ColumnData::Boolean(Vec::new()),
            DataType::Int64 => ColumnData::Int64(Vec::new()),
            DataType::Float64 => ColumnData::Float64(Vec::new()),
            DataType::Decimal { .. } => ColumnData::Decimal(Vec::new()),
            DataType::String | DataType::Null => ColumnData::String(Vec::new()),
            DataType::Date => ColumnData::Date(Vec::new()),
            DataType::Timestamp => ColumnData::Timestamp(Vec::new()),
        };
        let data_type = data_type.result_type();
        ColumnBuilder { data_type, data, validity: Bitmap::default() }
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
        Column { data_type: self.data_type, data: self.data, validity: self.validity }
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
    }
}
