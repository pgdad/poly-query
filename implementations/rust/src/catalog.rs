//! The catalog: named, immutable tables and the indexes on them
//! (case-insensitive names; index names are global).
//!
//! Tables are shared as `Arc<Table>` so that a running query keeps a snapshot
//! of the versions it references even if the catalog changes (concurrency.md §1).
//! An index refers to the exact table version it was built on; replacing or
//! dropping a table drops its indexes.

use std::collections::BTreeMap;
use std::sync::Arc;

use crate::error::{Error, ErrorCode, Result};
use crate::storage::pqcf::IndexMeta;
use crate::storage::{Index, IndexKind, Table};

#[derive(Debug, Default, Clone)]
pub struct Catalog {
    /// Keyed by ASCII-lowercased name, which also yields the required
    /// case-insensitive listing order.
    tables: BTreeMap<String, Arc<Table>>,
    /// All indexes, in creation order.
    indexes: Vec<Arc<Index>>,
}

fn key(name: &str) -> String {
    name.to_ascii_lowercase()
}

fn index_exists(name: &str) -> Error {
    Error::new(
        ErrorCode::AlreadyExists,
        format!("index '{name}' already exists"),
    )
}

impl Catalog {
    pub fn get(&self, name: &str) -> Option<Arc<Table>> {
        self.tables.get(&key(name)).cloned()
    }

    pub fn contains(&self, name: &str) -> bool {
        self.tables.contains_key(&key(name))
    }

    /// Adds or replaces a table. Without `replace`, an existing name is
    /// `ALREADY_EXISTS`. Indexes of a replaced table are dropped.
    pub fn insert(&mut self, table: Table, replace: bool) -> Result<Arc<Table>> {
        self.insert_with_indexes(table, replace, &[])
    }

    /// Adds or replaces a table and creates the given indexes on it
    /// (`open` of a PQCF file). Atomic: on any error nothing changes. An
    /// index name that exists on another table (or on the replaced table
    /// after its indexes are dropped) is `ALREADY_EXISTS`.
    pub fn insert_with_indexes(
        &mut self,
        table: Table,
        replace: bool,
        index_defs: &[IndexMeta],
    ) -> Result<Arc<Table>> {
        let k = key(&table.name);
        let old = self.tables.get(&k).cloned();
        if !replace && old.is_some() {
            return Err(Error::new(
                ErrorCode::AlreadyExists,
                format!("table '{}' already exists", table.name),
            ));
        }
        let survives = |ix: &Arc<Index>| old.as_ref().is_none_or(|t| !Arc::ptr_eq(&ix.table, t));
        for def in index_defs {
            if self
                .indexes
                .iter()
                .any(|ix| survives(ix) && ix.name.eq_ignore_ascii_case(&def.name))
            {
                return Err(index_exists(&def.name));
            }
        }
        let t = Arc::new(table);
        let mut built = Vec::with_capacity(index_defs.len());
        for def in index_defs {
            let column = t.column_index(&def.column).ok_or_else(|| {
                Error::new(
                    ErrorCode::StorageCorrupt,
                    format!("index '{}' references an unknown column", def.name),
                )
            })?;
            built.push(Arc::new(Index::build(
                &def.name,
                t.clone(),
                column,
                def.kind,
            )?));
        }
        self.indexes.retain(|ix| survives(ix));
        self.indexes.extend(built);
        self.tables.insert(k, t.clone());
        Ok(t)
    }

    pub fn drop_table(&mut self, name: &str) -> Result<()> {
        let t = self
            .tables
            .remove(&key(name))
            .ok_or_else(|| Error::not_found(format!("table '{name}' does not exist")))?;
        self.indexes.retain(|ix| !Arc::ptr_eq(&ix.table, &t));
        Ok(())
    }

    pub fn clear(&mut self) {
        self.tables.clear();
        self.indexes.clear();
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

    pub fn index(&self, name: &str) -> Option<&Arc<Index>> {
        self.indexes
            .iter()
            .find(|ix| ix.name.eq_ignore_ascii_case(name))
    }

    /// Indexes on (this version of) `table`, in creation order.
    pub fn indexes_for(&self, table: &Arc<Table>) -> Vec<Arc<Index>> {
        self.indexes
            .iter()
            .filter(|ix| Arc::ptr_eq(&ix.table, table))
            .cloned()
            .collect()
    }

    /// Builds and registers an index (`CREATE INDEX`).
    pub fn create_index(
        &mut self,
        name: &str,
        table: &Arc<Table>,
        column: usize,
        kind: IndexKind,
    ) -> Result<()> {
        if self.index(name).is_some() {
            return Err(index_exists(name));
        }
        let ix = Index::build(name, table.clone(), column, kind)?;
        self.indexes.push(Arc::new(ix));
        Ok(())
    }

    /// Removes an index; returns false if it does not exist.
    pub fn drop_index(&mut self, name: &str) -> bool {
        let before = self.indexes.len();
        self.indexes
            .retain(|ix| !ix.name.eq_ignore_ascii_case(name));
        self.indexes.len() != before
    }
}
