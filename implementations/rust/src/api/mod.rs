//! The embedding API: the engine as an in-process library
//! (`spec/apps/embedding.md`).
//!
//! ```no_run
//! use polyquery::api::{Config, Database, LoadOptions, Value};
//!
//! # fn main() -> polyquery::api::Result<()> {
//! let db = Database::create(Config::new("data"))?;
//! db.load_csv_text("t", "id,name\n1,ann\n2,bob\n", &LoadOptions::default())?;
//! let result = db.query("SELECT name FROM t WHERE id = 2")?;
//! assert_eq!(result.value(0, 0), Some(&Value::String("bob".into())));
//! db.close();
//! # Ok(())
//! # }
//! ```
//!
//! Everything a program needs is in this module; the other modules of the
//! crate are the engine's internals.
//!
//! A [`Database`] is `Send + Sync`: one instance may be shared by several
//! threads (e.g. in an `Arc`) and used concurrently. Every statement works
//! on a consistent snapshot of the tables; changes (loads, opens, drops)
//! are serialized and become visible atomically.

mod error;
mod value;

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};

pub use error::{Error, ErrorCode, Result};
pub use value::{Column, ColumnType, Date, Decimal, Timestamp, Value};

use crate::engine::{self, Engine, LoadRequest, OpenRequest, SaveRequest, Source};
use crate::ingest::{self, Format};
use crate::stack::{QUERY_STACK_BYTES, run_scoped};
use crate::storage::pqcf::write::SaveOptions;
use crate::storage::{Field, Layout, Table};
use crate::types::{self, DataType};

/// Largest accepted `threads` query option.
const MAX_QUERY_THREADS: usize = 256;

/// Configuration of a [`Database`] instance: the data directory and the
/// limits and defaults that `bin/polyquery` accepts as command-line options.
///
/// ```
/// let config = polyquery::api::Config::new("/var/lib/books")
///     .max_query_memory_mb(512)
///     .threads(4);
/// ```
#[derive(Debug, Clone)]
pub struct Config {
    inner: crate::config::Config,
}

impl Config {
    /// Default limits, with `data_dir` as the root of all file paths
    /// (`--data-dir`): load, save and open accept only relative paths
    /// without `..` components, resolved against it.
    pub fn new(data_dir: impl Into<PathBuf>) -> Self {
        Config {
            inner: crate::config::Config {
                data_dir: data_dir.into(),
                ..Default::default()
            },
        }
    }

    /// Per-query memory limit in MiB (`--max-query-memory-mb`, default 4096).
    pub fn max_query_memory_mb(mut self, mb: u64) -> Self {
        self.inner.max_query_memory_mb = mb;
        self
    }

    /// Default number of worker threads per query (`--threads`; default:
    /// the number of CPUs, at most 16).
    pub fn threads(mut self, threads: usize) -> Self {
        self.inner.threads = threads;
        self
    }

    /// Largest accepted load input in bytes (`--max-ingest-bytes`).
    pub fn max_ingest_bytes(mut self, bytes: u64) -> Self {
        self.inner.max_ingest_bytes = bytes;
        self
    }

    /// Largest number of rows of a table (`--max-table-rows`).
    pub fn max_table_rows(mut self, rows: u64) -> Self {
        self.inner.max_table_rows = rows;
        self
    }

    /// Largest number of rows a join may produce (`--max-join-rows`).
    pub fn max_join_rows(mut self, rows: u64) -> Self {
        self.inner.max_join_rows = rows;
        self
    }

    /// Default timeout of a query without its own (`--query-timeout-ms`,
    /// 0 = none).
    pub fn query_timeout_ms(mut self, ms: u64) -> Self {
        self.inner.query_timeout_ms = ms;
        self
    }

    /// Enables the test-only function `PQ_SLEEP` (`--enable-test-functions`).
    pub fn enable_test_functions(mut self, enabled: bool) -> Self {
        self.inner.test_functions = enabled;
        self
    }

    pub fn data_dir(&self) -> &Path {
        &self.inner.data_dir
    }
}

/// Options of [`Database::load_csv_file`] and [`Database::load_csv_text`].
#[derive(Debug, Clone)]
pub struct LoadOptions {
    /// The first record holds the column names (default true). Without a
    /// header an explicit `schema` is required.
    pub header: bool,
    /// Field delimiter, one ASCII character other than `"`, CR and LF
    /// (default `,`).
    pub delimiter: char,
    /// Explicit column names and types; None infers the types
    /// (`spec/data-types/ingestion.md`).
    pub schema: Option<Vec<Column>>,
    /// Replace an existing table of the same name (default false: the
    /// load fails with `ALREADY_EXISTS`).
    pub replace: bool,
}

impl Default for LoadOptions {
    fn default() -> Self {
        LoadOptions {
            header: true,
            delimiter: ',',
            schema: None,
            replace: false,
        }
    }
}

/// Options of [`Database::open`].
#[derive(Debug, Clone, Copy, Default)]
pub struct OpenOptions {
    /// Replace an existing table of the same name.
    pub replace: bool,
    /// Memory-map the file and decode its chunks on first use instead of
    /// reading it whole.
    pub mmap: bool,
}

/// Options of [`Database::query_with`]. `None` means the instance default.
#[derive(Debug, Clone, Copy, Default)]
pub struct QueryOptions {
    /// Worker threads for this query (≥ 1).
    pub threads: Option<usize>,
    /// Timeout in milliseconds; exceeding it fails with `TIMEOUT`.
    pub timeout_ms: Option<u64>,
    /// More result rows than this fail with `RESOURCE_LIMIT`.
    pub max_rows: Option<u64>,
}

/// Name, columns and row count of a table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TableInfo {
    pub name: String,
    pub columns: Vec<Column>,
    pub row_count: u64,
}

impl TableInfo {
    fn of(table: &Table) -> Self {
        TableInfo {
            name: table.name.clone(),
            columns: columns_of(&table.fields),
            row_count: table.row_count as u64,
        }
    }
}

fn columns_of(fields: &[Field]) -> Vec<Column> {
    fields
        .iter()
        .map(|f| Column::new(f.name.clone(), f.data_type.into()))
        .collect()
}

/// The result of a query: typed columns and rows of native [`Value`]s.
#[derive(Debug, Clone, PartialEq)]
pub struct QueryResult {
    columns: Vec<Column>,
    rows: Vec<Vec<Value>>,
}

impl QueryResult {
    /// The result columns (name and type) in select-list order.
    pub fn columns(&self) -> &[Column] {
        &self.columns
    }

    pub fn column_names(&self) -> impl Iterator<Item = &str> {
        self.columns.iter().map(|c| c.name.as_str())
    }

    pub fn column_types(&self) -> impl Iterator<Item = ColumnType> + '_ {
        self.columns.iter().map(|c| c.column_type)
    }

    /// Position of the first column with this name (ASCII
    /// case-insensitive).
    pub fn column_index(&self, name: &str) -> Option<usize> {
        self.columns
            .iter()
            .position(|c| c.name.eq_ignore_ascii_case(name))
    }

    pub fn row_count(&self) -> usize {
        self.rows.len()
    }

    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    /// All rows; each has one value per column.
    pub fn rows(&self) -> &[Vec<Value>] {
        &self.rows
    }

    pub fn row(&self, index: usize) -> Option<&[Value]> {
        self.rows.get(index).map(Vec::as_slice)
    }

    /// The value at (`row`, `column`).
    pub fn value(&self, row: usize, column: usize) -> Option<&Value> {
        self.rows.get(row).and_then(|r| r.get(column))
    }

    pub fn into_rows(self) -> Vec<Vec<Value>> {
        self.rows
    }

    pub fn into_parts(self) -> (Vec<Column>, Vec<Vec<Value>>) {
        (self.columns, self.rows)
    }
}

impl<'a> IntoIterator for &'a QueryResult {
    type Item = &'a Vec<Value>;
    type IntoIter = std::slice::Iter<'a, Vec<Value>>;

    fn into_iter(self) -> Self::IntoIter {
        self.rows.iter()
    }
}

/// An engine instance: a catalog of in-memory and file-backed tables and
/// a configuration. Created with [`Database::create`]; released with
/// [`Database::close`] or by dropping it.
///
/// Every operation runs in the calling process; errors leave the instance
/// usable. Statements run on a helper thread with a large, guarded stack
/// (the caller's thread blocks until they finish), so deeply nested
/// statements fail with `RESOURCE_LIMIT` instead of overflowing the
/// caller's stack.
pub struct Database {
    engine: Engine,
}

fn invalid(message: impl Into<String>) -> Error {
    Error::new(ErrorCode::InvalidRequest, message)
}

fn check_table_name(name: &str) -> Result<()> {
    if name.is_empty() {
        return Err(invalid("table name must not be empty"));
    }
    Ok(())
}

impl Database {
    /// Creates an instance. The data directory must exist (`NOT_FOUND`);
    /// zero limits are `INVALID_REQUEST`.
    pub fn create(config: Config) -> Result<Database> {
        let config = config.inner;
        if config.threads == 0 {
            return Err(invalid("threads must be at least 1"));
        }
        if config.max_query_memory_mb == 0 {
            return Err(invalid("max_query_memory_mb must be at least 1"));
        }
        if !config.data_dir.is_dir() {
            return Err(Error::new(
                ErrorCode::NotFound,
                format!(
                    "data directory '{}' does not exist",
                    config.data_dir.display()
                ),
            ));
        }
        Ok(Database {
            engine: Engine::new(config),
        })
    }

    /// The data directory all file paths are resolved against.
    pub fn data_dir(&self) -> &Path {
        &self.engine.config.data_dir
    }

    /// Runs an engine operation on a guarded thread, turning a panic into
    /// `INTERNAL_ERROR`.
    fn run<T: Send>(
        &self,
        op: impl FnOnce(&Engine) -> crate::error::Result<T> + Send,
    ) -> Result<T> {
        let engine = &self.engine;
        let outcome = run_scoped("polyquery-api", QUERY_STACK_BYTES, move || {
            catch_unwind(AssertUnwindSafe(|| op(engine)))
        });
        match outcome {
            Ok(Ok(Ok(result))) => result.map_err(Error::from),
            Ok(_) => Err(Error::new(
                ErrorCode::InternalError,
                "internal error while processing the request",
            )),
            Err(e) => Err(Error::new(
                ErrorCode::InternalError,
                format!("cannot start an engine thread: {e}"),
            )),
        }
    }

    /// Loads a CSV file (`path` relative to the data directory) into
    /// `table`. Errors: `ALREADY_EXISTS`, `ACCESS_DENIED` (path),
    /// `IO_ERROR`, `INGEST_ERROR`, `CONVERSION_ERROR`, `RESOURCE_LIMIT`,
    /// `INVALID_REQUEST` (options).
    pub fn load_csv_file(
        &self,
        table: &str,
        path: &str,
        options: &LoadOptions,
    ) -> Result<TableInfo> {
        self.load(table, Source::Path(path.to_string()), options)
    }

    /// Loads CSV text held in memory into `table` (errors as
    /// [`Database::load_csv_file`]).
    pub fn load_csv_text(
        &self,
        table: &str,
        csv: &str,
        options: &LoadOptions,
    ) -> Result<TableInfo> {
        self.load(table, Source::Data(csv.to_string()), options)
    }

    fn load(&self, table: &str, source: Source, options: &LoadOptions) -> Result<TableInfo> {
        check_table_name(table)?;
        let d = options.delimiter;
        if !d.is_ascii() || matches!(d, '"' | '\n' | '\r') {
            return Err(invalid("delimiter must be a single ASCII character"));
        }
        if !options.header && options.schema.is_none() {
            return Err(invalid("header=false requires an explicit schema"));
        }
        let request = LoadRequest {
            table: table.to_string(),
            format: Format::Csv,
            source,
            schema: options.schema.as_ref().map(|s| {
                s.iter()
                    .map(|c| Field::new(c.name.clone(), c.column_type.into()))
                    .collect()
            }),
            header: options.header,
            delimiter: d as u8,
            replace: options.replace,
            layout: Layout::default(),
            dictionary: None,
        };
        self.run(move |e| e.load(request).map(|t| TableInfo::of(&t)))
    }

    /// Creates `table` from native values: one `Vec<Value>` per row, one
    /// value per column, each NULL or of the column's type (`TYPE_ERROR`;
    /// DECIMAL values are rescaled to the column's scale if that is exact,
    /// else `CONVERSION_ERROR`; too many digits `NUMERIC_OVERFLOW`).
    /// Column names must be non-empty and unique (`INGEST_ERROR`).
    pub fn create_table(
        &self,
        table: &str,
        columns: &[Column],
        rows: Vec<Vec<Value>>,
        replace: bool,
    ) -> Result<TableInfo> {
        check_table_name(table)?;
        ingest::validate_names(columns.iter().map(|c| c.name.as_str()))?;
        if rows.len() as u64 > self.engine.config.max_table_rows {
            return Err(Error::new(
                ErrorCode::ResourceLimit,
                "too many rows for one table",
            ));
        }
        let mut converted = Vec::with_capacity(rows.len());
        for (n, row) in rows.into_iter().enumerate() {
            if row.len() != columns.len() {
                return Err(invalid(format!(
                    "row {} has {} values, expected {}",
                    n + 1,
                    row.len(),
                    columns.len()
                )));
            }
            let values = row
                .iter()
                .zip(columns)
                .map(|(v, c)| v.to_engine(c.column_type))
                .collect::<Result<Vec<_>>>()?;
            converted.push(values.into_boxed_slice());
        }
        let fields = columns
            .iter()
            .map(|c| Field::new(c.name.clone(), c.column_type.into()))
            .collect();
        let name = table.to_string();
        self.run(move |e| {
            let t =
                Table::from_rows(name, fields, converted).into_layout(Layout::default(), None)?;
            e.insert_table(t, replace).map(|t| TableInfo::of(&t))
        })
    }

    /// Executes a query and stores its result as `table` (like
    /// `CREATE TABLE … AS SELECT`). Errors: those of [`Database::query`],
    /// `ALREADY_EXISTS` without `replace`.
    pub fn create_table_from_query(
        &self,
        table: &str,
        sql: &str,
        replace: bool,
    ) -> Result<TableInfo> {
        check_table_name(table)?;
        let name = table.to_string();
        self.run(move |e| {
            let result = e.query(sql, &engine::QueryOptions::default())?;
            let fields: Vec<Field> = result
                .columns
                .iter()
                .map(|f| Field::new(f.name.clone(), f.data_type.result_type()))
                .collect();
            ingest::validate_names(fields.iter().map(|f| f.name.as_str()))?;
            let rows = result
                .rows
                .into_iter()
                .map(|row| {
                    row.into_iter()
                        .zip(&fields)
                        .map(|(v, f)| conform(v, f.data_type))
                        .collect::<Vec<_>>()
                        .into_boxed_slice()
                })
                .collect();
            let t = Table::from_rows(name, fields, rows).into_layout(Layout::default(), None)?;
            e.insert_table(t, replace).map(|t| TableInfo::of(&t))
        })
    }

    /// Executes one SQL statement with the instance defaults.
    pub fn query(&self, sql: &str) -> Result<QueryResult> {
        self.query_with(sql, &QueryOptions::default())
    }

    /// Executes one SQL statement (a query, `EXPLAIN`, `CREATE INDEX` or
    /// `DROP INDEX`). Errors: `PARSE_ERROR`, `SEMANTIC_ERROR`,
    /// `TYPE_ERROR`, runtime errors (`DIVISION_BY_ZERO`, …), `TIMEOUT`,
    /// `RESOURCE_LIMIT`, `INVALID_REQUEST` (options).
    pub fn query_with(&self, sql: &str, options: &QueryOptions) -> Result<QueryResult> {
        let mut opts = engine::QueryOptions::default();
        if let Some(t) = options.threads {
            if t == 0 {
                return Err(invalid("threads must be at least 1"));
            }
            opts.threads = Some(t.min(MAX_QUERY_THREADS));
        }
        opts.timeout_ms = options.timeout_ms.unwrap_or(0);
        opts.max_rows = options.max_rows;
        self.run(move |e| {
            let result = e.query(sql, &opts)?;
            let types: Vec<DataType> = result.columns.iter().map(|f| f.data_type).collect();
            let rows = result
                .rows
                .into_iter()
                .map(|row| {
                    row.into_iter()
                        .zip(&types)
                        .map(|(v, ty)| Value::from_engine(v, *ty))
                        .collect()
                })
                .collect();
            Ok(QueryResult {
                columns: columns_of(&result.columns),
                rows,
            })
        })
    }

    /// Writes `table` to a PQCF file (`path` relative to the data
    /// directory; written atomically, replacing an existing file). Returns
    /// the file size. Errors: `NOT_FOUND`, `ACCESS_DENIED`, `IO_ERROR`.
    pub fn save(&self, table: &str, path: &str) -> Result<u64> {
        let request = SaveRequest {
            table: table.to_string(),
            path: path.to_string(),
            options: SaveOptions::default(),
        };
        self.run(move |e| e.save(&request))
    }

    /// Opens a PQCF file (`path` relative to the data directory) as
    /// `table`. Errors: `ALREADY_EXISTS` (without `replace`),
    /// `ACCESS_DENIED`, `IO_ERROR`, `STORAGE_CORRUPT`,
    /// `STORAGE_VERSION_UNSUPPORTED`.
    pub fn open(&self, table: &str, path: &str, options: &OpenOptions) -> Result<TableInfo> {
        check_table_name(table)?;
        let request = OpenRequest {
            table: table.to_string(),
            path: path.to_string(),
            mmap: options.mmap,
            layout: None,
            dictionary: None,
            replace: options.replace,
        };
        self.run(move |e| e.open(&request).map(|t| TableInfo::of(&t)))
    }

    /// Removes a table (`NOT_FOUND` if there is none).
    pub fn drop_table(&self, table: &str) -> Result<()> {
        self.engine.drop_table(table).map_err(Error::from)
    }

    /// All tables, ordered by name (ASCII case-insensitively).
    pub fn tables(&self) -> Vec<TableInfo> {
        self.engine
            .catalog()
            .tables()
            .map(|t| TableInfo::of(t))
            .collect()
    }

    /// Name, columns and row count of one table (`NOT_FOUND`).
    pub fn table(&self, table: &str) -> Result<TableInfo> {
        let t = self.engine.table(table)?;
        Ok(TableInfo::of(&t))
    }

    /// The columns of a table (`NOT_FOUND`).
    pub fn schema(&self, table: &str) -> Result<Vec<Column>> {
        Ok(self.table(table)?.columns)
    }

    /// Releases the instance: its tables, and the files it has opened.
    /// Equivalent to dropping it.
    pub fn close(self) {
        drop(self);
    }
}

/// Gives an engine value the representation of its column type (DECIMAL
/// values at the column's scale).
fn conform(v: types::Value, ty: DataType) -> types::Value {
    match (v, ty) {
        (types::Value::Decimal(u, s), DataType::Decimal { scale, .. }) if s != scale => {
            types::decimal::rescale(u, s, scale).map_or(types::Value::Decimal(u, s), |r| {
                types::Value::Decimal(r, scale)
            })
        }
        (types::Value::Int(i), DataType::Decimal { scale, .. }) => {
            types::decimal::rescale(i as i128, 0, scale)
                .map_or(types::Value::Int(i), |r| types::Value::Decimal(r, scale))
        }
        (types::Value::Int(i), DataType::Float64) => types::Value::Float(i as f64),
        (v, _) => v,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pq-api-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn assert_send_sync<T: Send + Sync>() {}

    #[test]
    fn database_is_thread_safe() {
        assert_send_sync::<Database>();
    }

    #[test]
    fn load_query_save_open() {
        let dir = temp_dir("roundtrip");
        let db = Database::create(Config::new(&dir).threads(2)).unwrap();
        let info = db
            .load_csv_text(
                "t",
                "id,amount,day\n1,10.50,2026-01-01\n2,-3.25,2026-01-02\n",
                &LoadOptions::default(),
            )
            .unwrap();
        assert_eq!(info.row_count, 2);
        let r = db
            .query("SELECT id, amount, day, NULL AS n FROM t ORDER BY id")
            .unwrap();
        assert_eq!(
            r.column_names().collect::<Vec<_>>(),
            ["id", "amount", "day", "n"]
        );
        assert_eq!(r.columns()[1].column_type.name(), "FLOAT64");
        assert_eq!(r.value(0, 0), Some(&Value::Int64(1)));
        assert_eq!(r.value(1, 1), Some(&Value::Float64(-3.25)));
        assert_eq!(
            r.value(0, 2),
            Some(&Value::Date(Date::from_ymd(2026, 1, 1).unwrap()))
        );
        assert_eq!(r.value(0, 3), Some(&Value::Null));
        db.save("t", "t.pqcf").unwrap();
        db.open("u", "t.pqcf", &OpenOptions::default()).unwrap();
        assert_eq!(db.schema("u").unwrap(), db.schema("t").unwrap());
        assert_eq!(
            db.tables()
                .iter()
                .map(|t| t.name.as_str())
                .collect::<Vec<_>>(),
            ["t", "u"]
        );
        db.drop_table("u").unwrap();
        assert_eq!(db.drop_table("u").unwrap_err().code(), ErrorCode::NotFound);
        db.close();
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn errors_carry_codes_and_leave_the_instance_usable() {
        let dir = temp_dir("errors");
        let db = Database::create(Config::new(&dir)).unwrap();
        assert_eq!(
            db.query("SELEC 1").unwrap_err().code(),
            ErrorCode::ParseError
        );
        let e = db.query("SELECT x FROM nowhere").unwrap_err();
        assert_eq!(e.code_str(), "SEMANTIC_ERROR");
        assert!(e.to_string().starts_with("SEMANTIC_ERROR: "));
        let e = db
            .load_csv_file("t", "../x.csv", &LoadOptions::default())
            .unwrap_err();
        assert_eq!(e.code(), ErrorCode::AccessDenied);
        assert_eq!(db.query("SELECT 1 AS one").unwrap().row_count(), 1);
        let e = Database::create(Config::new(dir.join("missing")))
            .err()
            .unwrap();
        assert_eq!(e.code(), ErrorCode::NotFound);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn tables_from_values_and_queries() {
        let dir = temp_dir("values");
        let db = Database::create(Config::new(&dir)).unwrap();
        let columns = [
            Column::new("id", ColumnType::Int64),
            Column::new(
                "amount",
                ColumnType::Decimal {
                    precision: 18,
                    scale: 2,
                },
            ),
        ];
        let rows = vec![
            vec![Value::Int64(1), Value::Decimal(Decimal::new(5, 1))],
            vec![Value::Int64(2), Value::Null],
        ];
        db.create_table("v", &columns, rows, false).unwrap();
        let r = db.query("SELECT SUM(amount) AS s FROM v").unwrap();
        assert_eq!(r.value(0, 0).unwrap().to_string(), "0.50");
        let bad = vec![vec![Value::String("x".into()), Value::Null]];
        assert_eq!(
            db.create_table("w", &columns, bad, false)
                .unwrap_err()
                .code(),
            ErrorCode::TypeError
        );
        let info = db
            .create_table_from_query("w", "SELECT id * 2 AS id2 FROM v", false)
            .unwrap();
        assert_eq!(info.row_count, 2);
        assert_eq!(
            db.create_table_from_query("w", "SELECT 1 AS x", false)
                .unwrap_err()
                .code(),
            ErrorCode::AlreadyExists
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
