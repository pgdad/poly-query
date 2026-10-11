//! The engine facade: catalog operations, ingestion and query execution,
//! independent of the transport (session, exec, HTTP).

use std::path::{Component, Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, RwLock};
use std::time::{Duration, Instant};

use crate::catalog::Catalog;
use crate::config::Config;
use crate::error::{Error, ErrorCode, Result};
use crate::exec::{ExecContext, ExecOptions, Operator, Row, build};
use crate::ingest::{self, Format, IngestOptions};
use crate::json::Json;
use crate::planner::physical::{self, JoinStrategy};
use crate::planner::{BindContext, PhysicalOptions, PhysicalPlan, optimizer, plan_query};
use crate::sql::ast::Ident;
use crate::sql::ast::{Query, Statement};
use crate::sql::parse_statement;
use crate::storage::pqcf::write::SaveOptions;
use crate::storage::pqcf::{self, IndexMeta};
use crate::storage::{Field, Index, IndexKind, Layout, Table, TableStats};
use crate::types::{DataType, Value};

/// Where load input comes from.
#[derive(Debug, Clone)]
pub enum Source {
    /// Path relative to the data directory.
    Path(String),
    /// Inline content.
    Data(String),
}

#[derive(Debug, Clone)]
pub struct LoadRequest {
    pub table: String,
    pub format: Format,
    pub source: Source,
    pub schema: Option<Vec<Field>>,
    pub header: bool,
    pub delimiter: u8,
    pub replace: bool,
    /// In-memory representation (`options.layout`).
    pub layout: Layout,
    /// `options.dictionary`: Some(true) forces dictionary encoding of STRING
    /// columns; None applies it where beneficial.
    pub dictionary: Option<bool>,
}

/// `save` request (protocol.md §5.7).
#[derive(Debug, Clone)]
pub struct SaveRequest {
    pub table: String,
    pub path: String,
    pub options: SaveOptions,
}

/// `open` request (protocol.md §5.7).
#[derive(Debug, Clone)]
pub struct OpenRequest {
    pub table: String,
    pub path: String,
    /// Memory-map the file and decode chunks lazily.
    pub mmap: bool,
    /// Convert to this layout (None keeps the columnar file representation).
    pub layout: Option<Layout>,
    pub dictionary: Option<bool>,
    pub replace: bool,
}

#[derive(Debug, Clone)]
pub struct QueryOptions {
    /// Result rows above this ⇒ RESOURCE_LIMIT.
    pub max_rows: Option<u64>,
    /// 0 = no timeout.
    pub timeout_ms: u64,
    /// Count rows only, without materializing them.
    pub count_only: bool,
    /// Join algorithm preference.
    pub join: JoinStrategy,
    /// `use_indexes: false` ⇒ never use indexes.
    pub use_indexes: bool,
    /// Execution model (`mode`).
    pub mode: ExecMode,
    /// Worker threads (`threads`; None = the `--threads` default).
    pub threads: Option<usize>,
    /// `optimize: false` disables logical rewrites.
    pub optimize: bool,
    /// Client-assigned id used for cancellation (HTTP).
    pub query_id: Option<String>,
}

/// Query option `mode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ExecMode {
    /// Vectorized execution (the engine's default).
    #[default]
    Auto,
    /// Row-at-a-time baseline.
    Row,
    Vectorized,
}

impl Default for QueryOptions {
    fn default() -> Self {
        QueryOptions {
            max_rows: None,
            timeout_ms: 0,
            count_only: false,
            join: JoinStrategy::Auto,
            use_indexes: true,
            mode: ExecMode::Auto,
            threads: None,
            optimize: true,
            query_id: None,
        }
    }
}

impl QueryOptions {
    fn physical(&self) -> PhysicalOptions {
        PhysicalOptions {
            join: self.join,
            use_indexes: self.use_indexes,
        }
    }
}

#[derive(Debug)]
pub struct QueryResult {
    pub columns: Vec<Field>,
    /// Empty when `count_only` was requested.
    pub rows: Vec<Row>,
    pub row_count: u64,
}

/// How a running query is interrupted (concurrency.md §3–§4).
#[derive(Debug, Clone, Default)]
pub struct QueryControl {
    /// Absolute deadline; overrides `QueryOptions::timeout_ms` when set
    /// (the HTTP server counts queue time toward the timeout).
    pub deadline: Option<Instant>,
    /// Set to request cancellation.
    pub cancel: Option<Arc<AtomicBool>>,
}

/// The engine: configuration plus a catalog shared by concurrent requests.
///
/// The catalog is an immutable value behind a lock that is only held long
/// enough to clone or swap an `Arc`: every statement works on a snapshot
/// (concurrency.md §1), and mutations build a new catalog version and publish
/// it atomically. Mutations are serialized by `writer`; expensive work
/// (parsing input, opening files, building indexes) happens before the
/// catalog lock is taken, so readers are never blocked by it.
pub struct Engine {
    pub config: Config,
    catalog: RwLock<Arc<Catalog>>,
    writer: Mutex<()>,
}

impl Engine {
    pub fn new(config: Config) -> Self {
        Engine {
            config,
            catalog: RwLock::new(Arc::new(Catalog::default())),
            writer: Mutex::new(()),
        }
    }

    /// The current catalog version.
    pub fn catalog(&self) -> Arc<Catalog> {
        self.catalog
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Serializes catalog mutations.
    fn lock_writer(&self) -> MutexGuard<'_, ()> {
        self.writer.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Applies `f` to a copy of the current catalog and publishes the result
    /// if `f` succeeds (atomic: on error nothing changes). The caller must
    /// hold the writer lock.
    fn publish<T>(&self, f: impl FnOnce(&mut Catalog) -> Result<T>) -> Result<T> {
        let mut next = Catalog::clone(&self.catalog());
        let out = f(&mut next)?;
        *self.catalog.write().unwrap_or_else(PoisonError::into_inner) = Arc::new(next);
        Ok(out)
    }

    /// Runs a mutation of the catalog, serialized with all other mutations.
    fn mutate<T>(&self, f: impl FnOnce(&mut Catalog) -> Result<T>) -> Result<T> {
        let _guard = self.lock_writer();
        self.publish(f)
    }

    /// Resolves a request path inside the data directory (protocol.md §6).
    pub fn resolve_path(&self, path: &str) -> Result<PathBuf> {
        let denied = |why: &str| {
            Error::new(
                ErrorCode::AccessDenied,
                format!("path '{path}' is not allowed: {why}"),
            )
        };
        if path.is_empty() {
            return Err(denied("empty path"));
        }
        if path.contains('\0') {
            return Err(denied("contains NUL"));
        }
        let p = Path::new(path);
        if p.is_absolute() || path.starts_with('/') || path.starts_with('\\') {
            return Err(denied("absolute paths are not permitted"));
        }
        for c in p.components() {
            match c {
                Component::ParentDir => return Err(denied("'..' components are not permitted")),
                Component::Prefix(_) | Component::RootDir => {
                    return Err(denied("absolute paths are not permitted"));
                }
                _ => {}
            }
        }
        if path.split(['/', '\\']).any(|seg| seg == "..") {
            return Err(denied("'..' components are not permitted"));
        }
        Ok(self.config.data_dir.join(p))
    }

    fn read_input(&self, path: &str) -> Result<String> {
        let full = self.resolve_path(path)?;
        let meta = std::fs::metadata(&full).map_err(|e| io_error(path, e))?;
        if meta.is_dir() {
            return Err(Error::new(
                ErrorCode::IoError,
                format!("'{path}' is a directory"),
            ));
        }
        if meta.len() > self.config.max_ingest_bytes {
            return Err(Error::resource_limit(format!(
                "input of {} bytes exceeds the ingestion limit of {} bytes",
                meta.len(),
                self.config.max_ingest_bytes
            )));
        }
        let bytes = std::fs::read(&full).map_err(|e| io_error(path, e))?;
        String::from_utf8(bytes).map_err(|_| Error::ingest(format!("'{path}' is not valid UTF-8")))
    }

    /// Loads a table (parse first, then publish atomically).
    pub fn load(&self, mut req: LoadRequest) -> Result<Arc<Table>> {
        if !req.replace && self.catalog().contains(&req.table) {
            return Err(Error::new(
                ErrorCode::AlreadyExists,
                format!("table '{}' already exists", req.table),
            ));
        }
        let text = match std::mem::replace(&mut req.source, Source::Data(String::new())) {
            Source::Path(p) => self.read_input(&p)?,
            Source::Data(d) => {
                if d.len() as u64 > self.config.max_ingest_bytes {
                    return Err(Error::resource_limit(
                        "inline data exceeds the ingestion limit",
                    ));
                }
                d
            }
        };
        let opts = IngestOptions {
            header: req.header,
            delimiter: req.delimiter,
            schema: req.schema.clone(),
            max_rows: usize::try_from(self.config.max_table_rows).unwrap_or(usize::MAX),
        };
        let table = ingest::ingest(&req.table, req.format, &text, &opts)?
            .into_layout(req.layout, req.dictionary)?;
        self.mutate(|c| c.insert(table, req.replace))
    }

    fn max_rows(&self) -> usize {
        usize::try_from(self.config.max_table_rows).unwrap_or(usize::MAX)
    }

    /// Writes a table as a PQCF file atomically; returns the file size.
    pub fn save(&self, req: &SaveRequest) -> Result<u64> {
        let table = self.table(&req.table)?;
        let path = self.resolve_path(&req.path)?;
        let indexes: Vec<IndexMeta> = self
            .catalog()
            .indexes_for(&table)
            .iter()
            .map(|ix| IndexMeta {
                name: ix.name.clone(),
                column: ix.column_name().to_string(),
                kind: ix.kind,
            })
            .collect();
        pqcf::write::save(&table, &indexes, &path, &req.path, &req.options)
    }

    /// Opens a PQCF file as a table, recreating the indexes it lists.
    pub fn open(&self, req: &OpenRequest) -> Result<Arc<Table>> {
        if !req.replace && self.catalog().contains(&req.table) {
            return Err(Error::new(
                ErrorCode::AlreadyExists,
                format!("table '{}' already exists", req.table),
            ));
        }
        let path = self.resolve_path(&req.path)?;
        let opened = pqcf::read::open(&path, &req.path, &req.table, req.mmap, self.max_rows())?;
        let mut table = opened.table;
        if let Some(layout) = req.layout {
            table = table.into_layout(layout, req.dictionary)?;
        } else if req.dictionary == Some(true) {
            table = table.into_layout(Layout::Column, Some(true))?;
        }
        self.mutate(|c| c.insert_with_indexes(table, req.replace, &opened.indexes))
    }

    /// Statistics of a table (`stats` op).
    pub fn stats(&self, name: &str) -> Result<(Arc<Table>, TableStats)> {
        let table = self.table(name)?;
        let stats = table.stats()?;
        Ok((table, stats))
    }

    /// Indexes on a table, in creation order.
    pub fn indexes(&self, table: &Arc<Table>) -> Vec<Arc<Index>> {
        self.catalog().indexes_for(table)
    }

    /// `CREATE INDEX` (semantics.md §14).
    fn create_index(
        &self,
        name: &Ident,
        if_not_exists: bool,
        table: &Ident,
        column: &Ident,
        using: Option<&Ident>,
    ) -> Result<()> {
        // Index builds are serialized with other mutations; queries keep
        // running on their snapshots meanwhile.
        let _guard = self.lock_writer();
        let t = self.catalog().get(&table.value).ok_or_else(|| {
            table
                .pos
                .error(Error::semantic(format!("unknown table '{}'", table.value)))
        })?;
        let col = t.column_index(&column.value).ok_or_else(|| {
            column.pos.error(Error::semantic(format!(
                "unknown column '{}'",
                column.value
            )))
        })?;
        let kind = match using {
            None => IndexKind::Btree,
            Some(k) => IndexKind::parse(&k.value).ok_or_else(|| {
                Error::unsupported(format!("index kind '{}' is not supported", k.value))
            })?,
        };
        if self.catalog().index(&name.value).is_some() {
            if if_not_exists {
                return Ok(());
            }
            return Err(Error::new(
                ErrorCode::AlreadyExists,
                format!("index '{}' already exists", name.value),
            ));
        }
        let index = Arc::new(Index::build(&name.value, t, col, kind)?);
        self.publish(|c| c.add_index(index))
    }

    /// `DROP INDEX` (semantics.md §14).
    fn drop_index(&self, name: &Ident, if_exists: bool) -> Result<()> {
        self.mutate(|c| {
            if c.drop_index(&name.value) || if_exists {
                Ok(())
            } else {
                Err(Error::not_found(format!(
                    "index '{}' does not exist",
                    name.value
                )))
            }
        })
    }

    pub fn drop_table(&self, name: &str) -> Result<()> {
        self.mutate(|c| c.drop_table(name))
    }

    pub fn reset(&self) {
        let _ = self.mutate(|c| {
            c.clear();
            Ok(())
        });
    }

    pub fn table(&self, name: &str) -> Result<Arc<Table>> {
        self.catalog()
            .get(name)
            .ok_or_else(|| Error::not_found(format!("table '{name}' does not exist")))
    }

    /// Binds, optimizes and physically plans a query against a catalog snapshot.
    fn plan_query(
        &self,
        catalog: &Catalog,
        q: &Query,
        opts: &QueryOptions,
    ) -> Result<PhysicalPlan> {
        let ctx = BindContext {
            catalog,
            test_functions: self.config.test_functions,
            optimize: opts.optimize,
        };
        let logical = optimizer::optimize(plan_query(q, &ctx)?, opts.optimize);
        Ok(physical::lower(&logical, opts.physical()))
    }

    /// The physical plan of a query (`explain` op; also accepts `EXPLAIN …`).
    pub fn explain(&self, sql: &str, opts: &QueryOptions) -> Result<Json> {
        match parse_statement(sql)? {
            Statement::Query(q) | Statement::Explain(q) => {
                Ok(self.plan_query(&self.catalog(), &q, opts)?.to_json())
            }
            Statement::CreateIndex { .. } | Statement::DropIndex { .. } => {
                Err(Error::unsupported("only queries can be explained"))
            }
        }
    }

    /// Executes a SQL statement and materializes its result.
    pub fn query(&self, sql: &str, opts: &QueryOptions) -> Result<QueryResult> {
        self.start_query(sql, opts, QueryControl::default())?
            .collect(opts.count_only)
    }

    /// Parses and plans a SQL statement and returns a cursor producing its
    /// result rows incrementally. Statements (`CREATE/DROP INDEX`) are
    /// executed here and yield an empty cursor. A query plans against a
    /// snapshot of the catalog and keeps the table versions it references
    /// for its whole execution.
    pub fn start_query(
        &self,
        sql: &str,
        opts: &QueryOptions,
        control: QueryControl,
    ) -> Result<QueryCursor> {
        let ready = |columns: Vec<Field>, rows: Vec<Row>| QueryCursor {
            columns,
            source: CursorSource::Ready(rows.into_iter()),
            ctx: ExecContext::default(),
            max_rows: opts.max_rows,
            row_count: 0,
            replay: None,
        };
        match parse_statement(sql)? {
            Statement::Query(q) => {
                let plan = self.plan_query(&self.catalog(), &q, opts)?;
                let columns = plan
                    .schema()
                    .iter()
                    .map(|f| Field::new(f.name.clone(), f.data_type.result_type()))
                    .collect();
                let timeout_ms = if opts.timeout_ms > 0 {
                    opts.timeout_ms
                } else {
                    self.config.query_timeout_ms
                };
                let timeout = (timeout_ms > 0).then(|| Duration::from_millis(timeout_ms));
                let deadline = control
                    .deadline
                    .or_else(|| timeout.map(|t| Instant::now() + t));
                let memory =
                    usize::try_from(self.config.max_query_memory_mb.saturating_mul(1024 * 1024))
                        .unwrap_or(usize::MAX);
                let exec = ExecOptions {
                    vectorized: opts.mode != ExecMode::Row,
                    threads: opts.threads.unwrap_or(self.config.threads).max(1),
                };
                let make_ctx = |exec: ExecOptions| {
                    let ctx = ExecContext::new(None, memory, self.config.test_functions)
                        .with_deadline(deadline)
                        .with_max_join_rows(self.config.max_join_rows)
                        .with_physical_options(opts.physical())
                        .with_exec_options(exec);
                    match &control.cancel {
                        Some(flag) => ctx.with_cancel_flag(flag.clone()),
                        None => ctx,
                    }
                };
                let ctx = make_ctx(exec);
                ctx.check_interrupt()?;
                // A vectorized/parallel execution that fails is re-run with
                // the row-at-a-time reference engine (see `QueryCursor`).
                let replay = exec
                    .vectorized
                    .then(|| (plan.clone(), make_ctx(ExecOptions::default())));
                Ok(QueryCursor {
                    columns,
                    source: CursorSource::Plan(build(plan, &ctx)),
                    ctx,
                    max_rows: opts.max_rows,
                    row_count: 0,
                    replay,
                })
            }
            Statement::Explain(q) => {
                let plan = self.plan_query(&self.catalog(), &q, opts)?;
                let text = plan.to_json().to_string_compact();
                Ok(ready(
                    vec![Field::new("plan", DataType::String)],
                    vec![vec![Value::str(&text)]],
                ))
            }
            Statement::CreateIndex {
                name,
                if_not_exists,
                table,
                column,
                using,
            } => {
                self.create_index(&name, if_not_exists, &table, &column, using.as_ref())?;
                Ok(ready(Vec::new(), Vec::new()))
            }
            Statement::DropIndex { name, if_exists } => {
                self.drop_index(&name, if_exists)?;
                Ok(ready(Vec::new(), Vec::new()))
            }
        }
    }
}

enum CursorSource {
    /// A physical operator tree being executed.
    Plan(Box<dyn Operator>),
    /// Precomputed rows (EXPLAIN, statements).
    Ready(std::vec::IntoIter<Row>),
}

/// An executing statement: pulls result rows one at a time, enforcing
/// `max_rows`, the timeout and cancellation.
///
/// Error replay: vectorized and parallel execution evaluate expressions
/// eagerly over whole batches and in a different order than the row engine,
/// so when such an execution fails with a data error (overflow, division by
/// zero, conversion, …) before any row has been delivered, the statement is
/// transparently re-executed by the row-at-a-time engine, whose result or
/// error is then reported. Every execution mode therefore reports exactly
/// the baseline's errors (e.g. `LIMIT 1` over a later failing row succeeds).
pub struct QueryCursor {
    columns: Vec<Field>,
    source: CursorSource,
    ctx: ExecContext,
    max_rows: Option<u64>,
    row_count: u64,
    /// Plan and context for a row-mode re-execution (vectorized queries).
    replay: Option<(PhysicalPlan, ExecContext)>,
}

impl QueryCursor {
    /// Result columns (types are the protocol result types).
    pub fn columns(&self) -> &[Field] {
        &self.columns
    }

    /// Rows produced so far.
    pub fn row_count(&self) -> u64 {
        self.row_count
    }

    /// Switches to row-mode re-execution after `e`, if possible.
    fn try_replay(&mut self, e: &Error) -> bool {
        let replayable = !matches!(
            e.code,
            ErrorCode::Timeout | ErrorCode::Cancelled | ErrorCode::ResourceLimit
        );
        if !replayable {
            return false;
        }
        let Some((plan, ctx)) = self.replay.take() else {
            return false;
        };
        // Dropping the old operator tree stops its worker threads.
        self.source = CursorSource::Plan(build(plan, &ctx));
        self.ctx = ctx;
        self.row_count = 0;
        true
    }

    /// The next result row, or None at the end.
    pub fn next_row(&mut self) -> Result<Option<Row>> {
        loop {
            match self.pull() {
                Err(e) if self.row_count == 0 && self.try_replay(&e) => continue,
                r => return r,
            }
        }
    }

    fn pull(&mut self) -> Result<Option<Row>> {
        let row = match &mut self.source {
            // An internal failure of the vectorized engine is contained
            // and answered by the row-mode re-execution.
            CursorSource::Plan(root) if self.replay.is_some() => {
                let ctx = &self.ctx;
                crate::protocol::catch_panic(|| root.next(ctx))?
            }
            CursorSource::Plan(root) => root.next(&self.ctx)?,
            CursorSource::Ready(rows) => rows.next(),
        };
        if row.is_some() {
            self.row_count += 1;
            if let Some(max) = self.max_rows
                && self.row_count > max
            {
                return Err(Error::resource_limit(format!(
                    "result exceeds max_rows = {max}"
                )));
            }
        }
        Ok(row)
    }

    /// Fails with TIMEOUT or CANCELLED if the query must stop.
    pub fn check_interrupt(&self) -> Result<()> {
        self.ctx.check_interrupt()
    }

    /// Runs the query to completion counting rows (`result: "count"`).
    fn count(mut self) -> Result<QueryResult> {
        // One row beyond `max_rows` is enough to detect the violation.
        let max = self.max_rows.map_or(u64::MAX, |m| m.saturating_add(1));
        loop {
            let step = match &mut self.source {
                CursorSource::Plan(root) if self.replay.is_some() => {
                    let ctx = &self.ctx;
                    let left = max - self.row_count;
                    crate::protocol::catch_panic(|| root.skip(ctx, left))
                }
                CursorSource::Plan(root) => root.skip(&self.ctx, max - self.row_count),
                CursorSource::Ready(rows) => Ok(rows.by_ref().take(max as usize).count() as u64),
            };
            match step {
                Ok(0) => break,
                Ok(n) => {
                    self.row_count += n;
                    if let Some(m) = self.max_rows
                        && self.row_count > m
                    {
                        return Err(Error::resource_limit(format!(
                            "result exceeds max_rows = {m}"
                        )));
                    }
                }
                Err(e) => {
                    if !self.try_replay(&e) {
                        return Err(e);
                    }
                }
            }
        }
        Ok(QueryResult {
            columns: self.columns,
            rows: Vec::new(),
            row_count: self.row_count,
        })
    }

    /// Runs the query to completion, keeping the rows unless `count_only`.
    pub fn collect(mut self, count_only: bool) -> Result<QueryResult> {
        if count_only {
            return self.count();
        }
        let mut rows = Vec::new();
        loop {
            let row = match self.pull() {
                Ok(Some(row)) => row,
                Ok(None) => break,
                Err(e) => {
                    if self.try_replay(&e) {
                        rows.clear();
                        continue;
                    }
                    return Err(e);
                }
            };
            if !count_only {
                self.ctx
                    .reserve(row.iter().map(|v| v.approx_size()).sum::<usize>() + 24)?;
                rows.push(row);
            }
        }
        Ok(QueryResult {
            columns: self.columns,
            rows,
            row_count: self.row_count,
        })
    }
}

fn io_error(path: &str, e: std::io::Error) -> Error {
    match e.kind() {
        std::io::ErrorKind::NotFound => Error::not_found(format!("file '{path}' not found")),
        std::io::ErrorKind::PermissionDenied => Error::new(
            ErrorCode::AccessDenied,
            format!("permission denied for '{path}'"),
        ),
        _ => Error::new(ErrorCode::IoError, format!("cannot read '{path}': {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Value;

    fn engine() -> Engine {
        let e = Engine::new(Config::default());
        load(&e, "t", "id,name,amt\n1,a,1.5\n2,b,\n3,c,0.25\n");
        e
    }

    fn rows(e: &Engine, sql: &str) -> Vec<Row> {
        e.query(sql, &QueryOptions::default())
            .unwrap_or_else(|err| panic!("{sql}: {err}"))
            .rows
    }

    #[test]
    fn path_safety() {
        let e = Engine::new(Config::default());
        for bad in ["", "/etc/passwd", "../x", "a/../../b", "a/..", "x\0y"] {
            assert_eq!(
                e.resolve_path(bad).unwrap_err().code,
                ErrorCode::AccessDenied,
                "{bad:?}"
            );
        }
        assert!(e.resolve_path("fixtures/a.csv").is_ok());
    }

    #[test]
    fn select_filter_order_limit() {
        let e = engine();
        let r = rows(
            &e,
            "SELECT name FROM t WHERE id > 1 ORDER BY id DESC LIMIT 1",
        );
        assert_eq!(r, vec![vec![Value::str("c")]]);
        let r = rows(&e, "SELECT id FROM t ORDER BY amt NULLS LAST, id");
        assert_eq!(
            r,
            vec![
                vec![Value::Int(3)],
                vec![Value::Int(1)],
                vec![Value::Int(2)]
            ]
        );
    }

    #[test]
    fn aggregates() {
        let e = engine();
        let r = rows(&e, "SELECT COUNT(*), COUNT(amt), SUM(id), MAX(name) FROM t");
        assert_eq!(
            r,
            vec![vec![
                Value::Int(3),
                Value::Int(2),
                Value::Int(6),
                Value::str("c")
            ]]
        );
    }

    #[test]
    fn errors() {
        let e = engine();
        let code = |sql: &str| e.query(sql, &QueryOptions::default()).unwrap_err().code;
        assert_eq!(code("SELECT nope FROM t"), ErrorCode::SemanticError);
        assert_eq!(
            code("SELECT id FROM t WHERE name = 1"),
            ErrorCode::TypeError
        );
        assert_eq!(code("SELECT id, COUNT(*) FROM t"), ErrorCode::SemanticError);
        assert_eq!(
            code("SELECT id FROM t LIMIT -1"),
            ErrorCode::InvalidArgument
        );
        let max = QueryOptions {
            max_rows: Some(2),
            ..Default::default()
        };
        assert_eq!(
            e.query("SELECT id FROM t", &max).unwrap_err().code,
            ErrorCode::ResourceLimit
        );
    }

    fn load(e: &Engine, table: &str, csv: &str) {
        e.load(LoadRequest {
            table: table.into(),
            format: Format::Csv,
            source: Source::Data(csv.into()),
            schema: None,
            header: true,
            delimiter: b',',
            replace: false,
            layout: Layout::Column,
            dictionary: None,
        })
        .unwrap();
    }

    /// `t` plus `u(id, tag)` with a NULL key and an unmatched key.
    fn engine2() -> Engine {
        let e = engine();
        load(&e, "u", "id,tag\n1,x\n1,y\n3,z\n,w\n9,q\n");
        e
    }

    fn ints(v: &[i64]) -> Vec<Row> {
        v.iter().map(|&i| vec![Value::Int(i)]).collect()
    }

    #[test]
    fn joins() {
        let e = engine2();
        let r = rows(
            &e,
            "SELECT t.id, u.tag FROM t JOIN u ON t.id = u.id ORDER BY u.tag",
        );
        assert_eq!(
            r,
            vec![
                vec![Value::Int(1), Value::str("x")],
                vec![Value::Int(1), Value::str("y")],
                vec![Value::Int(3), Value::str("z")],
            ]
        );
        let r = rows(
            &e,
            "SELECT t.id FROM t LEFT JOIN u ON u.id = t.id WHERE u.tag IS NULL",
        );
        assert_eq!(r, ints(&[2]));
        let r = rows(&e, "SELECT COUNT(*) FROM t, u");
        assert_eq!(r, ints(&[15]));
        // Non-equi join (nested loop) and the explicit nested-loop strategy.
        let r = rows(&e, "SELECT COUNT(*) FROM t JOIN u ON t.id < u.id");
        assert_eq!(r, ints(&[5]));
        let nl = QueryOptions {
            join: JoinStrategy::NestedLoop,
            ..Default::default()
        };
        let r = e
            .query("SELECT COUNT(*) FROM t JOIN u ON t.id = u.id", &nl)
            .unwrap()
            .rows;
        assert_eq!(r, ints(&[3]));
    }

    #[test]
    fn grouping_and_distinct() {
        let e = engine2();
        let r = rows(
            &e,
            "SELECT id, COUNT(*) AS n FROM u GROUP BY id HAVING COUNT(*) > 1",
        );
        assert_eq!(r, vec![vec![Value::Int(1), Value::Int(2)]]);
        let r = rows(&e, "SELECT DISTINCT id FROM u ORDER BY id NULLS LAST");
        assert_eq!(
            r,
            vec![
                vec![Value::Int(1)],
                vec![Value::Int(3)],
                vec![Value::Int(9)],
                vec![Value::Null]
            ]
        );
        let r = rows(
            &e,
            "SELECT id + 1 AS k FROM u GROUP BY 1 ORDER BY k DESC LIMIT 1",
        );
        assert_eq!(r, ints(&[10]));
        let code = |sql: &str| e.query(sql, &QueryOptions::default()).unwrap_err().code;
        assert_eq!(
            code("SELECT tag FROM u GROUP BY id"),
            ErrorCode::SemanticError
        );
        assert_eq!(
            code("SELECT DISTINCT id FROM u ORDER BY tag"),
            ErrorCode::SemanticError
        );
    }

    #[test]
    fn subqueries_and_ctes() {
        let e = engine2();
        let r = rows(
            &e,
            "SELECT id FROM t WHERE id IN (SELECT id FROM u) ORDER BY id",
        );
        assert_eq!(r, ints(&[1, 3]));
        // NOT IN over a set containing NULL is never TRUE.
        let r = rows(&e, "SELECT id FROM t WHERE id NOT IN (SELECT id FROM u)");
        assert!(r.is_empty());
        // Correlated scalar subquery.
        let r = rows(
            &e,
            "SELECT t.id, (SELECT COUNT(*) FROM u WHERE u.id = t.id) FROM t ORDER BY 1",
        );
        assert_eq!(
            r,
            vec![
                vec![Value::Int(1), Value::Int(2)],
                vec![Value::Int(2), Value::Int(0)],
                vec![Value::Int(3), Value::Int(1)],
            ]
        );
        let r = rows(
            &e,
            "WITH a AS (SELECT id FROM t WHERE id > 1), b(x) AS (SELECT id * 10 FROM a) \
             SELECT x FROM b ORDER BY x",
        );
        assert_eq!(r, ints(&[20, 30]));
        let code = |sql: &str| e.query(sql, &QueryOptions::default()).unwrap_err().code;
        assert_eq!(
            code("SELECT (SELECT id FROM u)"),
            ErrorCode::SubqueryCardinality
        );
        assert_eq!(
            code("SELECT (SELECT id, tag FROM u)"),
            ErrorCode::SemanticError
        );
        assert_eq!(
            code("WITH a AS (SELECT * FROM a) SELECT 1"),
            ErrorCode::SemanticError
        );
    }

    #[test]
    fn explain() {
        let e = engine2();
        let plan = e
            .explain(
                "SELECT t.name FROM t JOIN u ON t.id = u.id WHERE u.tag = 'x'",
                &QueryOptions::default(),
            )
            .unwrap()
            .to_string_compact();
        assert!(
            plan.contains(r#""op":"HashJoin","join_type":"INNER""#),
            "{plan}"
        );
        assert!(
            plan.contains(r#""table":"t","columns":["id","name"]"#),
            "{plan}"
        );
        let r = e
            .query("EXPLAIN SELECT 1", &QueryOptions::default())
            .unwrap();
        assert_eq!(r.columns, vec![Field::new("plan", DataType::String)]);
        assert_eq!(r.row_count, 1);
    }
}
