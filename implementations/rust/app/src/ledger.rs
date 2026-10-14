//! The ledger (spec/apps/pqledger.md §4): three PQCF files in the data
//! directory, read and written through the embedded engine.
//!
//! A [`Ledger`] owns an engine instance whose data directory is the
//! ledger's. It opens `transactions`, `batches` and `overrides` from their
//! files and can add the derived tables `rules`, `budgets` and `ledger`
//! (the transactions with their resolved category, §5.1), which are never
//! saved.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use polyquery::api::{
    Column, ColumnType, Config as EngineConfig, Database, Date, Decimal, OpenOptions, QueryResult,
    Value,
};

use crate::convert::Entry;
use crate::error::{AppError, Result};
use crate::output::MONEY;
use crate::rules::{Budget, Rule};

/// The category of transactions no rule or override matches.
pub const UNCATEGORIZED: &str = "uncategorized";

/// The stored tables, each in `NAME.pqcf`.
pub const TRANSACTIONS: &str = "transactions";
pub const BATCHES: &str = "batches";
pub const OVERRIDES: &str = "overrides";

/// The columns of a stored table, in file order.
pub fn schema(table: &str) -> Vec<Column> {
    let c = |name: &str, ty: ColumnType| Column::new(name, ty);
    match table {
        TRANSACTIONS => vec![
            c("id", ColumnType::Int64),
            c("account", ColumnType::String),
            c("date", ColumnType::Date),
            c("description", ColumnType::String),
            c("merchant", ColumnType::String),
            c("amount", MONEY),
            c("batch", ColumnType::Int64),
        ],
        BATCHES => vec![
            c("batch", ColumnType::Int64),
            c("account", ColumnType::String),
            c("file", ColumnType::String),
            c("imported", ColumnType::Int64),
            c("duplicates", ColumnType::Int64),
        ],
        OVERRIDES => vec![
            c("id", ColumnType::Int64),
            c("category", ColumnType::String),
        ],
        _ => unreachable!("not a ledger table: {table}"),
    }
}

fn file_name(table: &str) -> String {
    format!("{table}.pqcf")
}

/// A SQL string literal.
pub fn sql_string(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

/// Engine settings from the `[engine]` section.
#[derive(Debug, Clone, Copy, Default)]
pub struct EngineSettings {
    pub threads: Option<usize>,
    pub memory_mb: Option<u64>,
}

impl EngineSettings {
    fn database(self, dir: &Path) -> Result<Database> {
        let mut config = EngineConfig::new(dir);
        if let Some(t) = self.threads {
            config = config.threads(t);
        }
        if let Some(m) = self.memory_mb {
            config = config.max_query_memory_mb(m);
        }
        Ok(Database::create(config)?)
    }
}

/// Counts of one import (§6.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImportSummary {
    pub batch: i64,
    pub imported: usize,
    pub duplicates: usize,
}

/// An open ledger.
pub struct Ledger {
    db: Database,
    dir: PathBuf,
}

impl Ledger {
    /// True if `dir` holds a ledger (`transactions.pqcf` exists).
    pub fn exists(dir: &Path) -> bool {
        dir.join(file_name(TRANSACTIONS)).is_file()
    }

    /// Creates `dir` (with parents) and the three tables with zero rows.
    pub fn init(dir: &Path, engine: EngineSettings) -> Result<()> {
        if Ledger::exists(dir) {
            return Err(AppError::ledger(format!(
                "a ledger already exists in '{}'",
                dir.display()
            )));
        }
        std::fs::create_dir_all(dir)
            .map_err(|e| AppError::other(format!("cannot create '{}': {e}", dir.display())))?;
        let db = engine.database(dir)?;
        // transactions.pqcf marks the ledger as present, so it comes last.
        for table in [OVERRIDES, BATCHES, TRANSACTIONS] {
            db.create_table(table, &schema(table), Vec::new(), false)?;
            db.save(table, &file_name(table))?;
        }
        db.close();
        Ok(())
    }

    /// Opens the ledger in `dir` (ledger state error if there is none).
    pub fn open(dir: &Path, engine: EngineSettings) -> Result<Ledger> {
        if !Ledger::exists(dir) {
            return Err(AppError::ledger(format!(
                "no ledger in '{}' (run 'pqledger init' first)",
                dir.display()
            )));
        }
        let db = engine.database(dir)?;
        let options = OpenOptions {
            replace: false,
            mmap: true,
        };
        for table in [TRANSACTIONS, BATCHES, OVERRIDES] {
            let info = db.open(table, &file_name(table), &options)?;
            if info.columns != schema(table) {
                return Err(AppError::other(format!(
                    "{}: unexpected columns (not a pqledger ledger file)",
                    dir.join(file_name(table)).display()
                )));
            }
        }
        Ok(Ledger {
            db,
            dir: dir.to_path_buf(),
        })
    }

    /// Runs a query of the application; engine errors are unexpected
    /// (exit 7).
    pub fn query(&self, sql: &str) -> Result<QueryResult> {
        Ok(self.db.query(sql)?)
    }

    /// Runs a user's query: engine errors are reported as is.
    pub fn user_query(&self, sql: &str) -> std::result::Result<QueryResult, polyquery::api::Error> {
        self.db.query(sql)
    }

    /// Adds the table `rules` (`rule_no`, `category`, `pattern`).
    pub fn add_rules(&self, rules: &[Rule]) -> Result<()> {
        let columns = [
            Column::new("rule_no", ColumnType::Int64),
            Column::new("category", ColumnType::String),
            Column::new("pattern", ColumnType::String),
        ];
        let rows = rules
            .iter()
            .zip(1..)
            .map(|(r, n): (&Rule, i64)| {
                vec![
                    Value::Int64(n),
                    Value::String(r.category.clone()),
                    Value::String(r.pattern.clone()),
                ]
            })
            .collect();
        self.db.create_table("rules", &columns, rows, true)?;
        Ok(())
    }

    /// Adds the table `budgets` (`category`, `amount`).
    pub fn add_budgets(&self, budgets: &[Budget]) -> Result<()> {
        let columns = [
            Column::new("category", ColumnType::String),
            Column::new("amount", MONEY),
        ];
        let rows = budgets
            .iter()
            .map(|b| vec![Value::String(b.category.clone()), Value::Decimal(b.amount)])
            .collect();
        self.db.create_table("budgets", &columns, rows, true)?;
        Ok(())
    }

    /// Adds the table `ledger`: the transactions followed by their resolved
    /// category (override, else the first matching rule, else
    /// `uncategorized`). Requires the `rules` table. The rule patterns
    /// (stored upper-cased) become LIKE patterns (`*` → `%`, `?` → `_`;
    /// patterns contain neither `%` nor `_`) and are matched against the
    /// upper-cased distinct merchants only; `UPPER` maps ASCII letters only,
    /// so matching is ASCII case-insensitive.
    pub fn add_categorized_ledger(&self) -> Result<()> {
        let sql = format!(
            "WITH merchants AS (SELECT DISTINCT merchant FROM transactions), \
             patterns AS (SELECT rule_no, category, \
                 REPLACE(REPLACE(pattern, '*', '%'), '?', '_') AS like_pattern FROM rules), \
             first_match AS (SELECT m.merchant, MIN(p.rule_no) AS rule_no \
                 FROM merchants m JOIN patterns p ON UPPER(m.merchant) LIKE p.like_pattern \
                 GROUP BY m.merchant), \
             merchant_category AS (SELECT f.merchant, p.category \
                 FROM first_match f JOIN patterns p ON p.rule_no = f.rule_no) \
             SELECT t.id, t.account, t.\"date\", t.description, t.merchant, t.amount, t.batch, \
                 COALESCE(o.category, mc.category, {}) AS category \
             FROM transactions t \
             LEFT JOIN overrides o ON o.id = t.id \
             LEFT JOIN merchant_category mc ON mc.merchant = t.merchant \
             ORDER BY t.id",
            sql_string(UNCATEGORIZED)
        );
        self.db.create_table_from_query("ledger", &sql, true)?;
        Ok(())
    }

    /// Imports converted records of `file` into `account` (§6.4): records
    /// already in the ledger are skipped as duplicates, the rest get new
    /// ids, and a batch is recorded. Both files are replaced atomically
    /// only after both have been written.
    pub fn import(&self, account: &str, file: &str, entries: &[Entry]) -> Result<ImportSummary> {
        type Key = (i32, i64, String);
        let existing = self.query(&format!(
            "SELECT \"date\", amount, merchant, COUNT(*) AS n FROM transactions \
             WHERE account = {} GROUP BY \"date\", amount, merchant",
            sql_string(account)
        ))?;
        let mut in_ledger: HashMap<Key, i64> = HashMap::with_capacity(existing.row_count());
        for row in &existing {
            in_ledger.insert(
                (date_of(&row[0])?, cents_of(&row[1])?, string_of(&row[2])?),
                int_of(&row[3])?,
            );
        }
        let mut in_file: HashMap<Key, i64> = HashMap::new();
        for e in entries {
            *in_file.entry(key(e)).or_default() += 1;
        }
        // Of f records with a key that is l times in the ledger, the last
        // max(0, f − l) are new: skip the first min(f, l).
        let mut to_skip: HashMap<Key, i64> = in_file
            .iter()
            .map(|(k, &f)| (k.clone(), f.min(in_ledger.get(k).copied().unwrap_or(0))))
            .collect();
        let (max_id, max_batch) = self.max_ids()?;
        let batch = max_batch + 1;
        let mut rows = Vec::new();
        for e in entries {
            let skip = to_skip.get_mut(&key(e)).expect("counted key");
            if *skip > 0 {
                *skip -= 1;
                continue;
            }
            rows.push(vec![
                Value::Int64(max_id + 1 + rows.len() as i64),
                Value::String(account.to_string()),
                Value::Date(e.date),
                Value::String(e.description.clone()),
                Value::String(e.merchant.clone()),
                Value::Decimal(Decimal::new(e.cents as i128, 2)),
                Value::Int64(batch),
            ]);
        }
        let summary = ImportSummary {
            batch,
            imported: rows.len(),
            duplicates: entries.len() - rows.len(),
        };
        let batch_row = vec![
            Value::Int64(batch),
            Value::String(account.to_string()),
            Value::String(file.to_string()),
            Value::Int64(summary.imported as i64),
            Value::Int64(summary.duplicates as i64),
        ];
        let mut changed = vec![self.appended(BATCHES, "batch", vec![batch_row])?];
        if !rows.is_empty() {
            changed.push(self.appended(TRANSACTIONS, "id", rows)?);
        }
        self.replace_files(&changed)?;
        Ok(summary)
    }

    /// Largest transaction id and batch number (0 for an empty ledger).
    fn max_ids(&self) -> Result<(i64, i64)> {
        let r = self.query(
            "SELECT (SELECT MAX(id) FROM transactions) AS max_id, \
                    (SELECT MAX(batch) FROM batches) AS max_batch, \
                    (SELECT MAX(batch) FROM transactions) AS max_tx_batch",
        )?;
        let get = |c: usize| match r.value(0, c) {
            Some(Value::Null) | None => Ok(0),
            Some(v) => int_of(v),
        };
        Ok((get(0)?, get(1)?.max(get(2)?)))
    }

    /// Builds `<table>_next`: the table plus `rows`, ordered by `key`.
    fn appended(&self, table: &str, key: &str, rows: Vec<Vec<Value>>) -> Result<String> {
        let added = format!("{table}_added");
        let next = format!("{table}_next");
        self.db.create_table(&added, &schema(table), rows, true)?;
        self.db.create_table_from_query(
            &next,
            &format!("SELECT * FROM {table} UNION ALL SELECT * FROM {added} ORDER BY {key}"),
            true,
        )?;
        Ok(table.to_string())
    }

    /// Writes `<table>_next` of every changed table to a temporary file,
    /// then renames all of them over the ledger files.
    fn replace_files(&self, tables: &[String]) -> Result<()> {
        let temp = |t: &str| format!(".pqledger-{t}.pqcf.new");
        let cleanup = |done: &[&String]| {
            for t in done {
                let _ = std::fs::remove_file(self.dir.join(temp(t)));
            }
        };
        let mut written = Vec::new();
        for t in tables {
            if let Err(e) = self.db.save(&format!("{t}_next"), &temp(t)) {
                cleanup(&written);
                return Err(e.into());
            }
            written.push(t);
        }
        for t in tables {
            std::fs::rename(self.dir.join(temp(t)), self.dir.join(file_name(t))).map_err(|e| {
                cleanup(&written);
                AppError::other(format!("cannot replace {}: {e}", file_name(t)))
            })?;
        }
        Ok(())
    }

    /// Whether a transaction with this id exists.
    pub fn has_transaction(&self, id: i64) -> Result<bool> {
        let r = self.query(&format!(
            "SELECT COUNT(*) AS n FROM transactions WHERE id = {id}"
        ))?;
        Ok(r.value(0, 0).and_then(Value::as_i64).unwrap_or(0) > 0)
    }

    /// Sets (Some) or removes (None) the category override of a
    /// transaction and saves `overrides.pqcf`.
    pub fn set_override(&self, id: i64, category: Option<&str>) -> Result<()> {
        let mut sql = format!("SELECT id, category FROM overrides WHERE id <> {id}");
        if let Some(c) = category {
            let row = vec![Value::Int64(id), Value::String(c.to_string())];
            self.db
                .create_table("overrides_added", &schema(OVERRIDES), vec![row], true)?;
            sql.push_str(" UNION ALL SELECT id, category FROM overrides_added");
        }
        sql.push_str(" ORDER BY id");
        self.db
            .create_table_from_query("overrides_next", &sql, true)?;
        self.db.save("overrides_next", &file_name(OVERRIDES))?;
        Ok(())
    }

    pub fn close(self) {
        self.db.close();
    }
}

fn key(e: &Entry) -> (i32, i64, String) {
    (e.date.days_since_epoch(), e.cents, e.merchant.clone())
}

fn unexpected(v: &Value) -> AppError {
    AppError::other(format!("unexpected value {v:?} in the ledger"))
}

fn int_of(v: &Value) -> Result<i64> {
    v.as_i64().ok_or_else(|| unexpected(v))
}

fn date_of(v: &Value) -> Result<i32> {
    v.as_date()
        .map(Date::days_since_epoch)
        .ok_or_else(|| unexpected(v))
}

fn string_of(v: &Value) -> Result<String> {
    v.as_str().map(str::to_string).ok_or_else(|| unexpected(v))
}

/// An amount in cents.
pub fn cents_of(v: &Value) -> Result<i64> {
    v.as_decimal()
        .and_then(|d| d.rescale(2))
        .and_then(|d| i64::try_from(d.unscaled()).ok())
        .ok_or_else(|| unexpected(v))
}
