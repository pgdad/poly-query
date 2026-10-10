//! Single-column secondary indexes (indexes-and-planning.md §2).
//!
//! * `HASH`  — value → row ids; equality and IN lookups.
//! * `BTREE` — an ordered structure (a sorted permutation of the non-null
//!   values with their row ids) supporting equality and range lookups by
//!   binary search.
//!
//! NULLs are never indexed, so no lookup returns them. Lookups return row
//! ids in ascending order.

use std::cmp::Ordering;
use std::collections::HashMap;
use std::sync::Arc;

use super::Table;
use crate::error::Result;
use crate::types::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndexKind {
    Hash,
    Btree,
}

impl IndexKind {
    pub fn name(self) -> &'static str {
        match self {
            IndexKind::Hash => "HASH",
            IndexKind::Btree => "BTREE",
        }
    }

    /// Parses `HASH` / `BTREE` (ASCII case-insensitive).
    pub fn parse(s: &str) -> Option<IndexKind> {
        if s.eq_ignore_ascii_case("HASH") {
            Some(IndexKind::Hash)
        } else if s.eq_ignore_ascii_case("BTREE") {
            Some(IndexKind::Btree)
        } else {
            None
        }
    }
}

#[derive(Debug)]
enum IndexData {
    Hash(HashMap<Value, Vec<u32>>),
    /// Non-null keys in ascending order, with the row id of each key.
    Ordered {
        keys: Vec<Value>,
        rows: Vec<u32>,
    },
}

/// One bound of a range lookup.
#[derive(Debug, Clone, PartialEq)]
pub struct Bound {
    pub value: Value,
    pub inclusive: bool,
}

/// An index over one column of one table version.
#[derive(Debug)]
pub struct Index {
    pub name: String,
    pub kind: IndexKind,
    /// The indexed table (the exact version whose row ids are stored).
    pub table: Arc<Table>,
    pub column: usize,
    data: IndexData,
}

impl Index {
    /// Builds an index on column `column` of `table`.
    pub fn build(name: &str, table: Arc<Table>, column: usize, kind: IndexKind) -> Result<Index> {
        let col = table.column(column)?;
        let data = match kind {
            IndexKind::Hash => {
                let mut map: HashMap<Value, Vec<u32>> = HashMap::new();
                for i in 0..col.len() {
                    let v = col.value(i);
                    if !v.is_null() {
                        map.entry(v).or_default().push(i as u32);
                    }
                }
                IndexData::Hash(map)
            }
            IndexKind::Btree => {
                let mut entries: Vec<(Value, u32)> = (0..col.len())
                    .filter(|&i| !col.is_null(i))
                    .map(|i| (col.value(i), i as u32))
                    .collect();
                entries.sort_by(|a, b| a.0.sort_cmp(&b.0).then(a.1.cmp(&b.1)));
                let (keys, rows) = entries.into_iter().unzip();
                IndexData::Ordered { keys, rows }
            }
        };
        drop(col);
        Ok(Index {
            name: name.to_string(),
            kind,
            table,
            column,
            data,
        })
    }

    pub fn column_name(&self) -> &str {
        &self.table.fields[self.column].name
    }

    pub fn supports_range(&self) -> bool {
        self.kind == IndexKind::Btree
    }

    /// Rows whose value equals one of `values` (values of the column's own
    /// type family; NULLs match nothing).
    pub fn lookup_eq(&self, values: &[Value]) -> Vec<u32> {
        let mut out = Vec::new();
        for v in values.iter().filter(|v| !v.is_null()) {
            match &self.data {
                IndexData::Hash(map) => {
                    if let Some(ids) = map.get(v) {
                        out.extend_from_slice(ids);
                    }
                }
                IndexData::Ordered { .. } => {
                    let b = Bound {
                        value: v.clone(),
                        inclusive: true,
                    };
                    out.extend(self.lookup_range(Some(&b), Some(&b)));
                }
            }
        }
        out.sort_unstable();
        out.dedup();
        out
    }

    /// Rows whose value lies within the bounds (ordered indexes only).
    pub fn lookup_range(&self, lo: Option<&Bound>, hi: Option<&Bound>) -> Vec<u32> {
        let IndexData::Ordered { keys, rows } = &self.data else {
            return Vec::new();
        };
        let cmp = |k: &Value, b: &Value| k.compare(b).unwrap_or(Ordering::Equal);
        let start = match lo {
            None => 0,
            Some(b) if b.inclusive => keys.partition_point(|k| cmp(k, &b.value).is_lt()),
            Some(b) => keys.partition_point(|k| cmp(k, &b.value).is_le()),
        };
        let end = match hi {
            None => keys.len(),
            Some(b) if b.inclusive => keys.partition_point(|k| cmp(k, &b.value).is_le()),
            Some(b) => keys.partition_point(|k| cmp(k, &b.value).is_lt()),
        };
        if start >= end {
            return Vec::new();
        }
        let mut out = rows[start..end].to_vec();
        out.sort_unstable();
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::{ColumnBuilder, Field};
    use crate::types::DataType;

    fn table() -> Arc<Table> {
        let mut b = ColumnBuilder::new(DataType::Int64);
        for v in [5, 3, 9, 3, 1] {
            b.push(Value::Int(v));
        }
        b.push_null();
        Arc::new(Table::new(
            "t",
            vec![Field::new("x", DataType::Int64)],
            vec![b.finish()],
            6,
        ))
    }

    #[test]
    fn hash_lookup() {
        let ix = Index::build("i", table(), 0, IndexKind::Hash).unwrap();
        assert_eq!(ix.lookup_eq(&[Value::Int(3), Value::Int(9)]), vec![1, 2, 3]);
        assert!(ix.lookup_eq(&[Value::Null]).is_empty());
    }

    #[test]
    fn ordered_lookup() {
        let ix = Index::build("i", table(), 0, IndexKind::Btree).unwrap();
        let b = |v: i64, inclusive| Bound {
            value: Value::Int(v),
            inclusive,
        };
        assert_eq!(
            ix.lookup_range(Some(&b(3, true)), Some(&b(5, true))),
            vec![0, 1, 3]
        );
        assert_eq!(ix.lookup_range(Some(&b(3, false)), None), vec![0, 2]);
        assert_eq!(ix.lookup_range(None, Some(&b(3, false))), vec![4]);
        assert_eq!(ix.lookup_eq(&[Value::Int(3)]), vec![1, 3]);
        // Mixed-type bound: DECIMAL 4.5 against INT64 keys.
        let d = Bound {
            value: Value::Decimal(45, 1),
            inclusive: true,
        };
        assert_eq!(ix.lookup_range(Some(&d), None), vec![0, 2]);
    }
}
