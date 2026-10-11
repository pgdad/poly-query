//! Table storage (indexes-and-planning.md §1, pqcf-v1.md).
//!
//! A [`Table`] is immutable once built and has one of three physical
//! representations:
//!
//! * **column layout** — one typed vector per column plus a validity bitmap
//!   (STRING columns optionally dictionary-encoded);
//! * **row layout** — a vector of row tuples;
//! * **PQCF file** — the row groups of an opened PQCF file, decoded per
//!   column chunk on first access (memory-mapped or read into memory).
//!
//! Every table is a sequence of *row groups*; in-memory tables have a single
//! group, PQCF tables keep the file's groups together with the per-chunk
//! min/max/null statistics used for row-group skipping.

pub mod column;
pub mod index;
pub mod pqcf;
pub mod stats;

use std::borrow::Cow;
use std::sync::{Arc, OnceLock};

pub use column::{Bitmap, Column, ColumnBuilder, ColumnData};
pub use index::{Index, IndexKind};
pub use stats::{ColumnStats, TableStats};

use crate::error::{Error, Result};
use crate::types::{DataType, Value};
use pqcf::read::FileData;

/// Name and type of a column.
#[derive(Debug, Clone, PartialEq)]
pub struct Field {
    pub name: String,
    pub data_type: DataType,
}

impl Field {
    pub fn new(name: impl Into<String>, data_type: DataType) -> Self {
        Field {
            name: name.into(),
            data_type,
        }
    }
}

/// In-memory representation selected by the `layout` option.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Layout {
    Row,
    #[default]
    Column,
}

impl Layout {
    pub fn parse(s: &str) -> Option<Layout> {
        match s {
            "row" => Some(Layout::Row),
            "column" => Some(Layout::Column),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Layout::Row => "row",
            Layout::Column => "column",
        }
    }
}

/// Known statistics of one column chunk of a row group (for skipping).
#[derive(Debug, Clone, Default)]
pub struct Zone {
    pub null_count: Option<usize>,
    /// Exact bounds of the non-null values, if known.
    pub min: Option<Value>,
    pub max: Option<Value>,
}

/// A horizontal partition of a table.
#[derive(Debug, Clone)]
pub struct RowGroup {
    /// Index of the group's first row in the table.
    pub start: usize,
    pub len: usize,
    /// Per-column chunk statistics; empty if unknown.
    pub zones: Vec<Zone>,
}

#[derive(Debug)]
enum Data {
    Columns(Vec<Column>),
    Rows(Vec<Box<[Value]>>),
    File(FileData),
}

/// An immutable table.
#[derive(Debug)]
pub struct Table {
    pub name: String,
    pub fields: Vec<Field>,
    pub row_count: usize,
    groups: Vec<RowGroup>,
    data: Data,
    /// Per-column statistics, computed on first use.
    stats: Vec<OnceLock<Result<Arc<ColumnStats>>>>,
}

fn no_stats(n: usize) -> Vec<OnceLock<Result<Arc<ColumnStats>>>> {
    (0..n).map(|_| OnceLock::new()).collect()
}

fn single_group(row_count: usize) -> Vec<RowGroup> {
    if row_count == 0 {
        Vec::new()
    } else {
        vec![RowGroup {
            start: 0,
            len: row_count,
            zones: Vec::new(),
        }]
    }
}

impl Table {
    /// A column-layout table.
    pub fn new(
        name: impl Into<String>,
        fields: Vec<Field>,
        columns: Vec<Column>,
        row_count: usize,
    ) -> Self {
        debug_assert_eq!(fields.len(), columns.len());
        debug_assert!(columns.iter().all(|c| c.len() == row_count));
        Table {
            name: name.into(),
            stats: no_stats(fields.len()),
            fields,
            row_count,
            groups: single_group(row_count),
            data: Data::Columns(columns),
        }
    }

    /// A row-layout table.
    pub fn from_rows(name: impl Into<String>, fields: Vec<Field>, rows: Vec<Box<[Value]>>) -> Self {
        let row_count = rows.len();
        Table {
            name: name.into(),
            stats: no_stats(fields.len()),
            fields,
            row_count,
            groups: single_group(row_count),
            data: Data::Rows(rows),
        }
    }

    /// A table backed by an opened PQCF file.
    pub(crate) fn from_file(
        name: impl Into<String>,
        fields: Vec<Field>,
        groups: Vec<RowGroup>,
        data: FileData,
    ) -> Self {
        let row_count = groups.iter().map(|g| g.len).sum();
        Table {
            name: name.into(),
            stats: no_stats(fields.len()),
            fields,
            row_count,
            groups,
            data: Data::File(data),
        }
    }

    /// Index of a column by case-insensitive name.
    pub fn column_index(&self, name: &str) -> Option<usize> {
        self.fields
            .iter()
            .position(|f| f.name.eq_ignore_ascii_case(name))
    }

    pub fn with_name(mut self, name: &str) -> Self {
        self.name = name.to_string();
        self
    }

    pub fn layout(&self) -> Layout {
        match self.data {
            Data::Rows(_) => Layout::Row,
            Data::Columns(_) | Data::File(_) => Layout::Column,
        }
    }

    /// True for tables backed by a PQCF file.
    pub fn is_file_backed(&self) -> bool {
        matches!(self.data, Data::File(_))
    }

    pub fn row_groups(&self) -> &[RowGroup] {
        &self.groups
    }

    /// The decoded chunk of column `col` in row group `rg` (column-oriented
    /// representations only; values are indexed relative to the group).
    fn chunk(&self, rg: usize, col: usize) -> Result<&Column> {
        match &self.data {
            Data::Columns(cols) => Ok(&cols[col]),
            Data::File(f) => f.chunk(rg, col, self.fields[col].data_type, self.groups[rg].len),
            Data::Rows(_) => Err(Error::internal("row-layout table has no column chunks")),
        }
    }

    /// The decoded chunk of column `col` in row group `rg` for column-oriented
    /// representations; None for the row layout (use [`Table::row_slice`]).
    pub fn column_chunk(&self, rg: usize, col: usize) -> Result<Option<&Column>> {
        match &self.data {
            Data::Rows(_) => Ok(None),
            _ => self.chunk(rg, col).map(Some),
        }
    }

    /// Rows `[from, to)` of row group `rg` of a row-layout table (None for
    /// column-oriented representations).
    pub fn row_slice(&self, rg: usize, from: usize, to: usize) -> Option<&[Box<[Value]>]> {
        match &self.data {
            Data::Rows(rows) => {
                let start = self.groups[rg].start;
                Some(&rows[start + from..start + to])
            }
            _ => None,
        }
    }

    /// Appends rows `[from, to)` (relative to row group `rg`) projected to
    /// `columns`.
    pub fn read_group(
        &self,
        rg: usize,
        columns: &[usize],
        from: usize,
        to: usize,
        out: &mut Vec<Vec<Value>>,
    ) -> Result<()> {
        let base = out.len();
        if let Data::Rows(rows) = &self.data {
            let start = self.groups[rg].start;
            out.extend(
                rows[start + from..start + to]
                    .iter()
                    .map(|r| columns.iter().map(|&c| r[c].clone()).collect()),
            );
            return Ok(());
        }
        out.extend((from..to).map(|_| Vec::with_capacity(columns.len())));
        for &c in columns {
            let chunk = self.chunk(rg, c)?;
            for (row, i) in out[base..].iter_mut().zip(from..to) {
                row.push(chunk.value(i));
            }
        }
        Ok(())
    }

    /// The rows with the given ascending row ids, projected to `columns`.
    pub fn read_rows(&self, ids: &[u32], columns: &[usize]) -> Result<Vec<Vec<Value>>> {
        let mut out = Vec::with_capacity(ids.len());
        if let Data::Rows(rows) = &self.data {
            for &id in ids {
                let r = &rows[id as usize];
                out.push(columns.iter().map(|&c| r[c].clone()).collect());
            }
            return Ok(out);
        }
        let mut rg = 0;
        for &id in ids {
            let id = id as usize;
            while self.groups[rg].start + self.groups[rg].len <= id {
                rg += 1;
            }
            let off = id - self.groups[rg].start;
            let mut row = Vec::with_capacity(columns.len());
            for &c in columns {
                row.push(self.chunk(rg, c)?.value(off));
            }
            out.push(row);
        }
        Ok(out)
    }

    /// The value at (`row`, `col`).
    pub fn value(&self, row: usize, col: usize) -> Result<Value> {
        Ok(self
            .read_rows(&[row as u32], &[col])?
            .pop()
            .and_then(|mut r| r.pop())
            .unwrap_or(Value::Null))
    }

    /// The whole column `col` as one column vector.
    pub fn column(&self, col: usize) -> Result<Cow<'_, Column>> {
        let ty = self.fields[col].data_type;
        match &self.data {
            Data::Columns(cols) => Ok(Cow::Borrowed(&cols[col])),
            Data::File(_) if self.groups.len() == 1 => Ok(Cow::Borrowed(self.chunk(0, col)?)),
            Data::File(_) => {
                let mut b = ColumnBuilder::with_capacity(ty, self.row_count);
                for rg in 0..self.groups.len() {
                    let chunk = self.chunk(rg, col)?;
                    for i in 0..chunk.len() {
                        b.push(chunk.value(i));
                    }
                }
                Ok(Cow::Owned(b.finish()))
            }
            Data::Rows(rows) => {
                let mut b = ColumnBuilder::with_capacity(ty, rows.len());
                for r in rows {
                    b.push(r[col].clone());
                }
                Ok(Cow::Owned(b.finish()))
            }
        }
    }

    /// Decodes every column chunk (validating a PQCF file completely).
    pub fn load_all(&self) -> Result<()> {
        if let Data::File(_) = &self.data {
            for rg in 0..self.groups.len() {
                for c in 0..self.fields.len() {
                    self.chunk(rg, c)?;
                }
            }
        }
        Ok(())
    }

    /// Frees the raw bytes of a fully decoded PQCF table.
    pub(crate) fn release_file_source(&mut self) {
        if let Data::File(f) = &mut self.data {
            f.release_source();
        }
    }

    /// Converts to the requested in-memory layout. `dictionary`: Some(true)
    /// forces dictionary encoding of STRING columns, None applies it where
    /// beneficial (column layout only).
    pub fn into_layout(self, layout: Layout, dictionary: Option<bool>) -> Result<Table> {
        match layout {
            Layout::Row => {
                if matches!(self.data, Data::Rows(_)) {
                    return Ok(self);
                }
                let all: Vec<usize> = (0..self.fields.len()).collect();
                let mut rows = Vec::with_capacity(self.row_count);
                for rg in 0..self.groups.len() {
                    let mut buf = Vec::new();
                    self.read_group(rg, &all, 0, self.groups[rg].len, &mut buf)?;
                    rows.extend(buf.into_iter().map(Vec::into_boxed_slice));
                }
                Ok(Table::from_rows(self.name, self.fields, rows))
            }
            Layout::Column => {
                let encode = |c: Column| match dictionary {
                    Some(true) => c.into_dictionary(),
                    Some(false) => c,
                    None => c.maybe_dictionary(),
                };
                match self.data {
                    Data::Columns(cols) => {
                        let cols = cols.into_iter().map(encode).collect();
                        Ok(Table::new(self.name, self.fields, cols, self.row_count))
                    }
                    Data::Rows(_) => {
                        let mut cols = Vec::with_capacity(self.fields.len());
                        for c in 0..self.fields.len() {
                            cols.push(encode(self.column(c)?.into_owned()));
                        }
                        Ok(Table::new(self.name, self.fields, cols, self.row_count))
                    }
                    Data::File(_) if dictionary == Some(true) => {
                        let mut cols = Vec::with_capacity(self.fields.len());
                        for c in 0..self.fields.len() {
                            cols.push(encode(self.column(c)?.into_owned()));
                        }
                        Ok(Table::new(self.name, self.fields, cols, self.row_count))
                    }
                    Data::File(_) => Ok(self),
                }
            }
        }
    }

    /// Statistics of column `col`, computed on first use.
    pub fn column_stats(&self, col: usize) -> Result<Arc<ColumnStats>> {
        self.stats[col]
            .get_or_init(|| {
                let column = self.column(col)?;
                Ok(Arc::new(stats::column_stats(&column)))
            })
            .clone()
    }

    /// Statistics of the whole table (`stats` op).
    pub fn stats(&self) -> Result<TableStats> {
        let mut columns = Vec::with_capacity(self.fields.len());
        for c in 0..self.fields.len() {
            columns.push((*self.column_stats(c)?).clone());
        }
        Ok(TableStats {
            row_count: self.row_count,
            columns,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table() -> Table {
        let mut a = ColumnBuilder::new(DataType::Int64);
        let mut b = ColumnBuilder::new(DataType::String);
        for i in 0..100 {
            a.push(Value::Int(i));
            if i % 10 == 0 {
                b.push_null();
            } else {
                b.push(Value::str(if i % 2 == 0 { "even" } else { "odd" }));
            }
        }
        Table::new(
            "t",
            vec![
                Field::new("a", DataType::Int64),
                Field::new("b", DataType::String),
            ],
            vec![a.finish(), b.finish()],
            100,
        )
    }

    #[test]
    fn layouts_agree() {
        let col = table().into_layout(Layout::Column, None).unwrap();
        let row = table().into_layout(Layout::Row, None).unwrap();
        assert_eq!(row.layout(), Layout::Row);
        assert!(col.column(1).unwrap().is_dictionary());
        let mut x = Vec::new();
        let mut y = Vec::new();
        col.read_group(0, &[1, 0], 0, 100, &mut x).unwrap();
        row.read_group(0, &[1, 0], 0, 100, &mut y).unwrap();
        assert_eq!(x, y);
        assert_eq!(
            row.read_rows(&[3, 10], &[1]).unwrap(),
            vec![vec![Value::str("odd")], vec![Value::Null]]
        );
        let s = row.stats().unwrap();
        assert_eq!(s.columns[1].null_count, 10);
        assert_eq!(s.columns[1].distinct_count, 2);
        assert_eq!(s.columns[0].max, Some(Value::Int(99)));
    }
}
