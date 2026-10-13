//! The engine facade: catalog operations, ingestion and query execution,
//! independent of the transport (session, exec, HTTP).

use std::path::{Component, Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, RwLock};
use std::time::{Duration, Instant};

use crate::catalog::Catalog;
use crate::config::Config;
use crate::error::{Error, ErrorCode, Result};
use crate::exec::parallel::default_morsel_rows;
use crate::exec::{ExecContext, Operator, Row, build};
use crate::ingest::{self, Format, IngestOptions};
use crate::interrupt::{self, Interrupt};
use crate::json::Json;
use crate::planner::physical::{self, JoinStrategy};
use crate::planner::{
    BindContext, LogicalPlan, Optimizer, PhysicalOptions, PhysicalPlan, PhysicalQuery, plan_query,
};
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
    /// Rows per parallel morsel (tests; None = default).
    pub morsel_rows: Option<usize>,
    /// Client-assigned id used for cancellation (HTTP).
    pub query_id: Option<String>,
    /// `native: true`: use the native kernels when a library is loaded.
    pub native: bool,
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
            morsel_rows: None,
            native: false,
            query_id: None,
        }
    }
}

#[derive(Debug)]
pub struct QueryResult {
    pub columns: Vec<Field>,
    /// Empty when `count_only` was requested or the rows were serialized
    /// directly (`rows_json`).
    pub rows: Vec<Row>,
    pub row_count: u64,
    /// The rows as a JSON array (from [`QueryCursor::collect_json`]).
    pub rows_json: Option<String>,
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

/// Loads the library given with `--native-kernels`. A library that cannot
/// be loaded is reported and ignored: queries then use the engine's own
/// code paths (native kernels are optional, native-kernels.md).
fn load_native_kernels(config: &Config) {
    let Some(path) = &config.native_kernels else {
        return;
    };
    let path_json = Json::String(path.display().to_string());
    match crate::native::init(Some(path)) {
        Ok(Some(k)) => crate::log::info(
            "native kernels loaded",
            vec![
                ("path", path_json),
                ("variant", Json::str(k.variant())),
                ("available", Json::str(k.available_variants())),
            ],
        ),
        Ok(None) => {}
        Err(e) => crate::log::warn(
            "native kernels unavailable; using built-in code paths",
            vec![("path", path_json), ("error", Json::String(e))],
        ),
    }
}

impl Engine {
    pub fn new(config: Config) -> Self {
        load_native_kernels(&config);
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

    /// Binds a query against a catalog snapshot and optimizes it.
    fn logical_plan(
        &self,
        catalog: &Catalog,
        q: &Query,
        opts: &QueryOptions,
    ) -> Result<LogicalPlan> {
        let ctx = BindContext {
            catalog,
            test_functions: self.config.test_functions,
        };
        let t0 = Instant::now();
        let bound = plan_query(q, &ctx)?;
        interrupt::check()?;
        let t1 = Instant::now();
        let optimized = Optimizer::for_query(opts.optimize).optimize(bound);
        crate::log::debug(
            "statement bound",
            vec![
                ("bind_us", Json::uint((t1 - t0).as_micros() as u64)),
                ("optimize_us", Json::uint(t1.elapsed().as_micros() as u64)),
            ],
        );
        optimized
    }

    /// The query options that steer physical planning.
    fn physical_options(&self, opts: &QueryOptions) -> PhysicalOptions {
        PhysicalOptions {
            join: opts.join,
            use_indexes: opts.use_indexes,
            vectorized: opts.mode != ExecMode::Row,
            threads: opts.threads.unwrap_or(self.config.threads),
            native: opts.native,
        }
    }

    /// The physical plan of a query (`explain` op; also accepts `EXPLAIN …`).
    pub fn explain(&self, sql: &str, opts: &QueryOptions, control: QueryControl) -> Result<Json> {
        let interrupt = self.interrupt(opts, control);
        let _installed = interrupt::install(interrupt.clone());
        match parse_statement(sql)? {
            Statement::Query(q) | Statement::Explain(q) => {
                interrupt.check()?;
                self.explain_query(&q, opts, &interrupt)
            }
            Statement::CreateIndex { .. } | Statement::DropIndex { .. } => {
                Err(Error::unsupported("only queries can be explained"))
            }
        }
    }

    /// The EXPLAIN plan JSON of a query.
    fn explain_query(&self, q: &Query, opts: &QueryOptions, interrupt: &Interrupt) -> Result<Json> {
        let catalog = self.catalog();
        let logical = self.logical_plan(&catalog, q, opts)?;
        interrupt.check()?;
        let plan = physical::plan(&logical, &catalog, self.physical_options(opts));
        interrupt.check()?;
        let json = plan.to_json();
        interrupt.check()?;
        Ok(json)
    }

    /// The effective deadline of a statement received at `arrival`:
    /// `options.timeout_ms`, else the configured default (concurrency.md §3).
    pub fn deadline(&self, arrival: Instant, opts: &QueryOptions) -> Option<Instant> {
        let timeout_ms = if opts.timeout_ms > 0 {
            opts.timeout_ms
        } else {
            self.config.query_timeout_ms
        };
        (timeout_ms > 0).then(|| arrival + Duration::from_millis(timeout_ms))
    }

    /// How the statement is interrupted; without an explicit deadline the
    /// timeout counts from now.
    fn interrupt(&self, opts: &QueryOptions, control: QueryControl) -> Interrupt {
        Interrupt {
            deadline: control
                .deadline
                .or_else(|| self.deadline(Instant::now(), opts)),
            cancel: control.cancel,
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
        // The timeout covers parsing, binding, planning and execution
        // (CR-6 §4): the stages before execution poll the installed interrupt.
        let interrupt = self.interrupt(opts, control);
        let _installed = interrupt::install(interrupt.clone());
        let t0 = Instant::now();
        let statement = parse_statement(sql)?;
        interrupt.check()?;
        match statement {
            Statement::Query(q) => {
                let t1 = Instant::now();
                let catalog = self.catalog();
                let logical = self.logical_plan(&catalog, &q, opts)?;
                interrupt.check()?;
                let t2 = Instant::now();
                let physical_opts = self.physical_options(opts);
                let plan = physical::plan(&logical, &catalog, physical_opts);
                interrupt.check()?;
                if crate::log::enabled(crate::log::LogLevel::Debug) {
                    let us = |d: Duration| Json::uint(d.as_micros() as u64);
                    crate::log::debug(
                        "statement planned",
                        vec![
                            ("parse_us", us(t1 - t0)),
                            ("bind_optimize_us", us(t2 - t1)),
                            ("physical_us", us(t2.elapsed())),
                        ],
                    );
                }
                let columns = plan
                    .schema()
                    .iter()
                    .map(|f| Field::new(f.name.clone(), f.data_type.result_type()))
                    .collect();
                let deadline = interrupt.deadline;
                let memory =
                    usize::try_from(self.config.max_query_memory_mb.saturating_mul(1024 * 1024))
                        .unwrap_or(usize::MAX);
                let morsel_rows = opts.morsel_rows.unwrap_or_else(default_morsel_rows);
                let make_ctx = |plan: &PhysicalQuery| {
                    let ctx = ExecContext::new(None, memory, self.config.test_functions)
                        .with_deadline(deadline)
                        .with_max_join_rows(self.config.max_join_rows)
                        .with_plan(plan)
                        .with_morsel_rows(morsel_rows);
                    match &interrupt.cancel {
                        Some(flag) => ctx.with_cancel_flag(flag.clone()),
                        None => ctx,
                    }
                };
                let ctx = make_ctx(&plan);
                ctx.check_interrupt()?;
                // A vectorized/parallel execution that fails is re-run with
                // the row-at-a-time reference engine (see `QueryCursor`),
                // planned from the same logical plan.
                let replay = plan.execution.vectorized.then(|| {
                    let baseline = physical::plan(&logical, &catalog, physical_opts.row_baseline());
                    let ctx = make_ctx(&baseline);
                    (baseline.root, ctx)
                });
                Ok(QueryCursor {
                    columns,
                    source: CursorSource::Plan(build(plan.root, &ctx)),
                    ctx,
                    max_rows: opts.max_rows,
                    row_count: 0,
                    replay,
                })
            }
            Statement::Explain(q) => {
                let text = self
                    .explain_query(&q, opts, &interrupt)?
                    .to_string_compact();
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
        // A result completed after the deadline is a TIMEOUT (CR-6 §4).
        self.ctx.check_interrupt()?;
        Ok(QueryResult {
            columns: self.columns,
            rows: Vec::new(),
            row_count: self.row_count,
            rows_json: None,
        })
    }

    /// Runs the query to completion, serializing the rows directly into a
    /// JSON array (types.md §9) instead of materializing them; vectorized
    /// plans write straight from their column vectors.
    pub fn collect_json(mut self, count_only: bool) -> Result<QueryResult> {
        if count_only {
            return self.count();
        }
        let types: Vec<DataType> = self.columns.iter().map(|f| f.data_type).collect();
        let max = self.max_rows.map_or(u64::MAX, |m| m.saturating_add(1));
        let mut out = String::from("[");
        loop {
            let before = out.len();
            let step = match &mut self.source {
                CursorSource::Plan(root) if self.replay.is_some() => {
                    let ctx = &self.ctx;
                    let left = max - self.row_count;
                    let out = &mut out;
                    crate::protocol::catch_panic(|| root.write_json(ctx, out, &types, left))
                }
                CursorSource::Plan(root) => {
                    root.write_json(&self.ctx, &mut out, &types, max - self.row_count)
                }
                CursorSource::Ready(rows) => {
                    let mut n = 0;
                    for row in rows.by_ref().take((max - self.row_count) as usize) {
                        if out.len() > 1 {
                            out.push(',');
                        }
                        crate::protocol::write_row(&row, &types, &mut out);
                        n += 1;
                    }
                    Ok(n)
                }
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
                    self.ctx.reserve(out.len() - before)?;
                }
                Err(e) => {
                    if !self.try_replay(&e) {
                        return Err(e);
                    }
                    out.truncate(1);
                }
            }
        }
        out.push(']');
        self.ctx.check_interrupt()?;
        Ok(QueryResult {
            columns: self.columns,
            rows: Vec::new(),
            row_count: self.row_count,
            rows_json: Some(out),
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
        self.ctx.check_interrupt()?;
        Ok(QueryResult {
            columns: self.columns,
            rows,
            row_count: self.row_count,
            rows_json: None,
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
    fn union_all() {
        let e = engine2();
        let r = rows(
            &e,
            "SELECT id FROM t UNION ALL SELECT id FROM u WHERE id = 1 ORDER BY 1 DESC LIMIT 3",
        );
        assert_eq!(r, ints(&[3, 2, 1]));
        let r = rows(
            &e,
            "SELECT COUNT(*) FROM (SELECT id FROM t UNION ALL SELECT id FROM u) x",
        );
        assert_eq!(r, ints(&[8]));
        // Output types are the common types; names come from the first branch.
        let q = e
            .query(
                "SELECT NULL AS a, id AS b FROM t UNION ALL SELECT tag, amt FROM u, t",
                &QueryOptions::default(),
            )
            .unwrap();
        assert_eq!(
            q.columns,
            vec![
                Field::new("a", DataType::String),
                Field::new("b", DataType::Float64)
            ]
        );
        let code = |sql: &str| e.query(sql, &QueryOptions::default()).unwrap_err().code;
        assert_eq!(
            code("SELECT id, name FROM t UNION ALL SELECT id FROM u"),
            ErrorCode::SemanticError
        );
        assert_eq!(
            code("SELECT name FROM t UNION ALL SELECT id FROM u"),
            ErrorCode::TypeError
        );
        assert_eq!(
            code("SELECT id FROM t UNION ALL SELECT id FROM u ORDER BY name"),
            ErrorCode::SemanticError
        );
        assert_eq!(
            code("SELECT 9223372036854775807 UNION ALL SELECT CAST(1 AS DECIMAL(2,1))"),
            ErrorCode::NumericOverflow
        );
        let plan = e
            .explain(
                "SELECT id FROM t UNION ALL SELECT id FROM u",
                &QueryOptions::default(),
                QueryControl::default(),
            )
            .unwrap()
            .to_string_compact();
        assert!(plan.contains(r#""op":"UnionAll""#), "{plan}");
    }

    #[test]
    fn explain() {
        let e = engine2();
        let plan = e
            .explain(
                "SELECT t.name FROM t JOIN u ON t.id = u.id WHERE u.tag = 'x'",
                &QueryOptions::default(),
                QueryControl::default(),
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

    /// Every combination of mode, join algorithm, threads and optimize
    /// returns the row baseline's result (multiset; ordered queries in
    /// order) and errors. Tiny morsels force the parallel operators.
    #[test]
    fn execution_modes_agree() {
        let e = Engine::new(Config::default());
        let mut fact = String::from("id,k,grp,amt,tag\n");
        for i in 0..600 {
            let k = if i % 13 == 0 {
                String::new()
            } else {
                (i % 37).to_string()
            };
            let tag = ["red", "green", "blue", ""][i % 4];
            fact.push_str(&format!(
                "{i},{k},{},{}.{:02},{tag}\n",
                i % 7,
                i * 3 % 101,
                i % 100
            ));
        }
        load(&e, "f", &fact);
        let mut dim = String::from("k,label\n");
        for k in 0..40 {
            dim.push_str(&format!("{k},L{}\n", k % 5));
        }
        load(&e, "d", &dim);
        let queries = [
            (
                "SELECT grp, COUNT(*), SUM(amt), MIN(tag), MAX(k), AVG(amt) FROM f GROUP BY grp",
                false,
            ),
            (
                "SELECT COUNT(DISTINCT k), SUM(DISTINCT grp) FROM f WHERE amt > 10",
                false,
            ),
            (
                "SELECT d.label, COUNT(*), SUM(f.amt) FROM f JOIN d ON d.k = f.k GROUP BY d.label",
                false,
            ),
            (
                "SELECT f.id, d.label FROM f LEFT JOIN d ON d.k = f.k AND d.label <> 'L1'",
                false,
            ),
            ("SELECT id, amt FROM f ORDER BY amt DESC, id LIMIT 25", true),
            (
                "SELECT tag, k FROM f ORDER BY tag NULLS FIRST, k DESC, id",
                true,
            ),
            ("SELECT DISTINCT tag, grp FROM f", false),
            (
                "SELECT id FROM f WHERE k IN (SELECT k FROM d WHERE label = 'L2')",
                false,
            ),
            (
                "SELECT COUNT(*) FROM f a, d b WHERE a.k < b.k AND b.label = 'L3'",
                false,
            ),
            (
                "SELECT x.id, y.label, z.label FROM f x JOIN d y ON y.k = x.k \
                 JOIN d z ON z.k = x.grp WHERE z.label IN ('L1', 'L2')",
                false,
            ),
            ("SELECT 100 / (grp - 3) FROM f", false),
            (
                "SELECT id FROM f WHERE grp <> 3 AND 100 / (grp - 3) > 20",
                false,
            ),
            ("SELECT SUM(id * 4611686018427387904) FROM f", false),
            (
                "SELECT k, amt FROM f WHERE grp = 1 UNION ALL SELECT k, 0.5 FROM d \
                 UNION ALL SELECT k, id FROM f WHERE tag = 'red'",
                false,
            ),
            (
                "SELECT x, COUNT(*), SUM(y) FROM (SELECT tag AS x, amt AS y FROM f \
                 UNION ALL SELECT label, k FROM d) t GROUP BY x",
                false,
            ),
            (
                "WITH c AS (SELECT k, SUM(amt) AS s FROM f GROUP BY k) \
                 SELECT COUNT(*) FROM c WHERE s > (SELECT AVG(s) FROM c)",
                false,
            ),
            (
                "WITH c AS (SELECT grp, COUNT(*) AS n FROM f WHERE amt > 5 GROUP BY grp) \
                 SELECT a.grp, a.n, b.n FROM c a JOIN c b ON b.grp = a.grp + 1",
                false,
            ),
            (
                "WITH c AS (SELECT grp, MAX(tag) AS t FROM f GROUP BY grp) \
                 SELECT grp FROM c WHERE t IN (SELECT t FROM c WHERE grp > 2) \
                 AND EXISTS (SELECT 1 FROM c WHERE grp = 0)",
                false,
            ),
            (
                "SELECT id AS v FROM f UNION ALL SELECT k FROM d ORDER BY v DESC LIMIT 30",
                true,
            ),
            (
                "SELECT u.v, d.label FROM (SELECT k AS v FROM f UNION ALL SELECT k FROM d) u \
                 JOIN d ON d.k = u.v WHERE u.v > 30",
                false,
            ),
        ];
        let base = QueryOptions {
            mode: ExecMode::Row,
            join: JoinStrategy::Hash,
            threads: Some(1),
            ..Default::default()
        };
        let canon = |r: Result<QueryResult>, ordered: bool| match r {
            Ok(mut q) => {
                // FLOAT64 sums may differ in the last bits (summation order).
                let fmt = |v: &Value| match v {
                    Value::Float(f) => format!("{f:.9e}"),
                    v => format!("{v:?}"),
                };
                let mut rows: Vec<String> = q
                    .rows
                    .drain(..)
                    .map(|r| r.iter().map(fmt).collect::<Vec<_>>().join("|"))
                    .collect();
                if !ordered {
                    rows.sort();
                }
                Ok(rows)
            }
            Err(err) => Err(err.code),
        };
        for (sql, ordered) in queries {
            let expect = canon(e.query(sql, &base), ordered);
            for mode in [ExecMode::Row, ExecMode::Vectorized] {
                for join in [
                    JoinStrategy::Hash,
                    JoinStrategy::Merge,
                    JoinStrategy::NestedLoop,
                ] {
                    for threads in [1, 4] {
                        for optimize in [true, false] {
                            let opts = QueryOptions {
                                mode,
                                join,
                                threads: Some(threads),
                                optimize,
                                morsel_rows: Some(50),
                                ..Default::default()
                            };
                            let got = canon(e.query(sql, &opts), ordered);
                            assert_eq!(got, expect, "{sql} with {opts:?}");
                        }
                    }
                }
            }
        }
    }

    /// `native: true` (with the library built by `make -C native-kernels`)
    /// gives exactly the results and errors of the engine's own code.
    #[test]
    fn native_kernels_agree() {
        let lib = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../native-kernels/build/x86_64/libpqkernels.so");
        if !lib.exists() {
            eprintln!("libpqkernels not built; skipping");
            return;
        }
        let e = Engine::new(Config {
            native_kernels: Some(lib),
            ..Config::default()
        });
        assert!(crate::native::loaded().is_some());
        let mut f = String::from("id,k,grp,amt,d,ts\n");
        for i in 0..3000 {
            let k = if i % 11 == 0 {
                String::new()
            } else {
                (i % 37).to_string()
            };
            f.push_str(&format!(
                "{i},{k},{},{}.{:02},2024-01-{:02},2024-01-01 {:02}:00:00\n",
                i % 7,
                i * 3 % 101,
                i % 100,
                1 + i % 28,
                i % 24
            ));
        }
        load(&e, "f", &f);
        load(
            &e,
            "big",
            "g,v\n1,9223372036854775807\n1,1\n1,-5\n2,9223372036854775807\n2,1\n3,-9223372036854775808\n3,4\n",
        );
        let queries = [
            "SELECT id, amt FROM f WHERE k > 5 AND amt < 50.5",
            "SELECT id FROM f WHERE k < 2.5 OR k IS NULL",
            "SELECT id FROM f WHERE k = 2.5 OR id = 7",
            "SELECT COUNT(*) FROM f WHERE k <> 2.5",
            "SELECT id FROM f WHERE k BETWEEN 3 AND 9 AND grp >= 2 AND amt > 1",
            "SELECT id FROM f WHERE k < grp AND k IS NOT NULL",
            "SELECT id FROM f WHERE k IS NULL",
            "SELECT id FROM f WHERE d >= DATE '2024-01-15' AND d < TIMESTAMP '2024-01-20 00:00:01'",
            "SELECT id FROM f WHERE ts > DATE '2024-01-01' AND id > 2990",
            "SELECT id FROM f WHERE k > 9223372036854775807 OR k < -9223372036854775807",
            "SELECT id FROM f WHERE id < 2000 AND 100 / (grp - 3) < 0 LIMIT 3",
            "SELECT id FROM f WHERE id < 2000 AND 100 / (grp - 3) < 0 LIMIT 4",
            "SELECT grp, COUNT(*), SUM(k), AVG(k), MIN(k), MAX(amt), SUM(amt), COUNT(k) FROM f GROUP BY grp",
            "SELECT SUM(k), MIN(ts), MAX(ts), MIN(d), COUNT(k), SUM(amt), MIN(amt) FROM f WHERE id > 10",
            "SELECT DISTINCT k FROM f",
            "SELECT g, SUM(v), AVG(v), COUNT(v) FROM big WHERE g <> 2 GROUP BY g",
            "SELECT g, SUM(v) FROM big GROUP BY g",
            "SELECT SUM(v) FROM big WHERE g = 1",
            "SELECT SUM(v) FROM big",
            "SELECT a.id, b.v FROM f a JOIN big b ON b.g = a.grp WHERE a.id < 30",
        ];
        for sql in queries {
            for mode in [ExecMode::Row, ExecMode::Vectorized] {
                for threads in [1, 4] {
                    let opts = |native| QueryOptions {
                        mode,
                        threads: Some(threads),
                        morsel_rows: Some(64),
                        native,
                        ..Default::default()
                    };
                    let run = |native| match e.query(sql, &opts(native)) {
                        Ok(r) => {
                            // Parallel FLOAT64 sums depend on the morsel
                            // assignment (last bits), with or without kernels.
                            let fmt = |v: &Value| match v {
                                Value::Float(f) if threads > 1 => format!("{f:.9e}"),
                                v => format!("{v:?}"),
                            };
                            let mut rows: Vec<String> = r
                                .rows
                                .iter()
                                .map(|r| r.iter().map(fmt).collect::<Vec<_>>().join("|"))
                                .collect();
                            rows.sort();
                            Ok(rows)
                        }
                        Err(err) => Err(err.code),
                    };
                    assert_eq!(run(true), run(false), "{sql} ({mode:?}, {threads} threads)");
                }
            }
        }
        let code = |sql: &str| {
            e.query(
                sql,
                &QueryOptions {
                    native: true,
                    ..Default::default()
                },
            )
        };
        assert_eq!(
            code("SELECT SUM(v) FROM big WHERE g = 1").unwrap().rows,
            vec![vec![Value::Int(i64::MAX - 4)]]
        );
        assert_eq!(
            code("SELECT g, SUM(v) FROM big GROUP BY g")
                .unwrap_err()
                .code,
            ErrorCode::NumericOverflow
        );
    }

    /// Consumers that stop early (LIMIT) stop the parallel workers; this
    /// must neither hang nor change results.
    #[test]
    fn parallel_early_stop() {
        let e = Engine::new(Config::default());
        let mut csv = String::from("id,v\n");
        for i in 0..3000 {
            csv.push_str(&format!("{i},{}\n", i % 17));
        }
        load(&e, "t", &csv);
        for round in 0..200u64 {
            let limit = 30 + (round * 37) % 2000;
            let opts = QueryOptions {
                threads: Some(1 + (round as usize % 7)),
                morsel_rows: Some(5 + (round as usize % 11)),
                ..Default::default()
            };
            let sql = format!("SELECT id FROM t WHERE v <> 3 LIMIT {limit}");
            let r = e.query(&sql, &opts).unwrap();
            assert_eq!(r.row_count, limit);
            // Ordered gather: the first `limit` qualifying rows in scan order.
            let first: Vec<i64> = (0..3000)
                .filter(|i| i % 17 != 3)
                .take(limit as usize)
                .collect();
            let got: Vec<i64> = r
                .rows
                .iter()
                .map(|row| match row[0] {
                    Value::Int(i) => i,
                    _ => -1,
                })
                .collect();
            assert_eq!(got, first);
        }
    }

    #[test]
    fn repeated_aggregations_are_shared() {
        let e = engine();
        let catalog = e.catalog();
        let sql = "WITH c AS (SELECT name, SUM(id) AS s FROM t GROUP BY name) \
                   SELECT COUNT(*) FROM c WHERE s > (SELECT AVG(s) FROM c)";
        let Statement::Query(q) = crate::sql::parse_statement(sql).unwrap() else {
            panic!("not a query");
        };
        let opts = QueryOptions::default();
        let logical = e.logical_plan(&catalog, &q, &opts).unwrap();
        let plan = physical::plan(&logical, &catalog, e.physical_options(&opts));
        fn count_shared(p: &PhysicalPlan) -> usize {
            usize::from(matches!(p, PhysicalPlan::Shared { .. }))
                + p.children().into_iter().map(count_shared).sum::<usize>()
        }
        let shared = count_shared(&plan.root)
            + plan
                .subqueries
                .values()
                .map(|s| count_shared(&s.plan))
                .sum::<usize>();
        assert_eq!(shared, 2);
        assert_eq!(rows(&e, sql), vec![vec![Value::Int(1)]]);
    }
}
