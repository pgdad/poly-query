//! In-memory table storage (column-oriented, immutable once built).

pub mod column;

pub use column::{Column, ColumnBuilder, ColumnData};

use crate::types::DataType;

/// Name and type of a column.
#[derive(Debug, Clone, PartialEq)]
pub struct Field {
    pub name: String,
    pub data_type: DataType,
}

impl Field {
    pub fn new(name: impl Into<String>, data_type: DataType) -> Self {
        Field { name: name.into(), data_type }
    }
}

/// An immutable table: schema plus one column vector per field.
#[derive(Debug, Clone)]
pub struct Table {
    pub name: String,
    pub fields: Vec<Field>,
    pub columns: Vec<Column>,
    pub row_count: usize,
}

impl Table {
    pub fn new(name: impl Into<String>, fields: Vec<Field>, columns: Vec<Column>, row_count: usize) -> Self {
        debug_assert_eq!(fields.len(), columns.len());
        debug_assert!(columns.iter().all(|c| c.len() == row_count));
        Table { name: name.into(), fields, columns, row_count }
    }

    /// Index of a column by case-insensitive name.
    pub fn column_index(&self, name: &str) -> Option<usize> {
        self.fields.iter().position(|f| f.name.eq_ignore_ascii_case(name))
    }

    pub fn with_name(mut self, name: &str) -> Self {
        self.name = name.to_string();
        self
    }
}
