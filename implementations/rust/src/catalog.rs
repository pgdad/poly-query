//! The catalog: named, immutable tables (case-insensitive names).
//!
//! Tables are shared as `Arc<Table>` so that a running query keeps a snapshot
//! of the versions it references even if the catalog changes (concurrency.md §1).

use std::collections::BTreeMap;
use std::sync::Arc;

use crate::error::{Error, ErrorCode, Result};
use crate::storage::Table;

#[derive(Debug, Default, Clone)]
pub struct Catalog {
    /// Keyed by ASCII-lowercased name, which also yields the required
    /// case-insensitive listing order.
    tables: BTreeMap<String, Arc<Table>>,
}

fn key(name: &str) -> String {
    name.to_ascii_lowercase()
}

impl Catalog {
    pub fn get(&self, name: &str) -> Option<Arc<Table>> {
        self.tables.get(&key(name)).cloned()
    }

    pub fn contains(&self, name: &str) -> bool {
        self.tables.contains_key(&key(name))
    }

    /// Adds or replaces a table. Without `replace`, an existing name is
    /// `ALREADY_EXISTS`.
    pub fn insert(&mut self, table: Table, replace: bool) -> Result<Arc<Table>> {
        let k = key(&table.name);
        if !replace && self.tables.contains_key(&k) {
            return Err(Error::new(ErrorCode::AlreadyExists, format!("table '{}' already exists", table.name)));
        }
        let t = Arc::new(table);
        self.tables.insert(k, t.clone());
        Ok(t)
    }

    pub fn drop_table(&mut self, name: &str) -> Result<()> {
        self.tables
            .remove(&key(name))
            .map(|_| ())
            .ok_or_else(|| Error::not_found(format!("table '{name}' does not exist")))
    }

    pub fn clear(&mut self) {
        self.tables.clear();
    }

    /// Tables sorted by name, case-insensitively.
    pub fn tables(&self) -> impl Iterator<Item = &Arc<Table>> {
        self.tables.values()
    }

    pub fn len(&self) -> usize {
        self.tables.len()
    }

    pub fn is_empty(&self) -> bool {
        self.tables.is_empty()
    }
}
