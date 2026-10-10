//! The engine facade: catalog operations, ingestion and query execution,
//! independent of the transport (session, exec, HTTP).

use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use crate::catalog::Catalog;
use crate::config::Config;
use crate::error::{Error, ErrorCode, Result};
use crate::exec::{ExecContext, Row, build};
use crate::ingest::{self, Format, IngestOptions};
use crate::json::Json;
use crate::planner::physical::{self, JoinStrategy};
use crate::planner::{BindContext, PhysicalOptions, PhysicalPlan, optimizer, plan_query};
use crate::sql::ast::{Query, Statement};
use crate::sql::parse_statement;
use crate::storage::{Field, Table};
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
}

#[derive(Debug, Clone, Default)]
pub struct QueryOptions {
    /// Result rows above this ⇒ RESOURCE_LIMIT.
    pub max_rows: Option<u64>,
    /// 0 = no timeout.
    pub timeout_ms: u64,
    /// Count rows only, without materializing them.
    pub count_only: bool,
    /// Join algorithm preference.
    pub join: JoinStrategy,
}

impl QueryOptions {
    fn physical(&self) -> PhysicalOptions {
        PhysicalOptions { join: self.join }
    }
}

#[derive(Debug)]
pub struct QueryResult {
    pub columns: Vec<Field>,
    /// Empty when `count_only` was requested.
    pub rows: Vec<Row>,
    pub row_count: u64,
}

pub struct Engine {
    pub config: Config,
    catalog: Catalog,
}

impl Engine {
    pub fn new(config: Config) -> Self {
        Engine {
            config,
            catalog: Catalog::default(),
        }
    }

    pub fn catalog(&self) -> &Catalog {
        &self.catalog
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
    pub fn load(&mut self, req: LoadRequest) -> Result<Arc<Table>> {
        if !req.replace && self.catalog.contains(&req.table) {
            return Err(Error::new(
                ErrorCode::AlreadyExists,
                format!("table '{}' already exists", req.table),
            ));
        }
        let text = match &req.source {
            Source::Path(p) => self.read_input(p)?,
            Source::Data(d) => {
                if d.len() as u64 > self.config.max_ingest_bytes {
                    return Err(Error::resource_limit(
                        "inline data exceeds the ingestion limit",
                    ));
                }
                d.clone()
            }
        };
        let opts = IngestOptions {
            header: req.header,
            delimiter: req.delimiter,
            schema: req.schema.clone(),
            max_rows: usize::try_from(self.config.max_table_rows).unwrap_or(usize::MAX),
        };
        let table = ingest::ingest(&req.table, req.format, &text, &opts)?;
        self.catalog.insert(table, req.replace)
    }

    pub fn drop_table(&mut self, name: &str) -> Result<()> {
        self.catalog.drop_table(name)
    }

    pub fn reset(&mut self) {
        self.catalog.clear();
    }

    pub fn table(&self, name: &str) -> Result<Arc<Table>> {
        self.catalog
            .get(name)
            .ok_or_else(|| Error::not_found(format!("table '{name}' does not exist")))
    }

    /// Binds, optimizes and physically plans a query.
    fn plan_query(&self, q: &Query, opts: &QueryOptions) -> Result<PhysicalPlan> {
        let ctx = BindContext {
            catalog: &self.catalog,
            test_functions: self.config.test_functions,
        };
        let logical = optimizer::optimize(plan_query(q, &ctx)?);
        Ok(physical::lower(&logical, opts.physical()))
    }

    /// The physical plan of a query (`explain` op; also accepts `EXPLAIN …`).
    pub fn explain(&self, sql: &str, opts: &QueryOptions) -> Result<Json> {
        match parse_statement(sql)? {
            Statement::Query(q) | Statement::Explain(q) => Ok(self.plan_query(&q, opts)?.to_json()),
            Statement::CreateIndex { .. } | Statement::DropIndex { .. } => {
                Err(Error::unsupported("indexes are not supported"))
            }
        }
    }

    /// Executes a SQL statement.
    pub fn query(&self, sql: &str, opts: &QueryOptions) -> Result<QueryResult> {
        match parse_statement(sql)? {
            Statement::Query(q) => {
                let plan = self.plan_query(&q, opts)?;
                self.execute(plan, opts)
            }
            Statement::Explain(q) => {
                let plan = self.plan_query(&q, opts)?;
                let text = plan.to_json().to_string_compact();
                Ok(QueryResult {
                    columns: vec![Field::new("plan", DataType::String)],
                    rows: if opts.count_only {
                        Vec::new()
                    } else {
                        vec![vec![Value::str(&text)]]
                    },
                    row_count: 1,
                })
            }
            Statement::CreateIndex { .. } | Statement::DropIndex { .. } => {
                Err(Error::unsupported("indexes are not supported"))
            }
        }
    }

    fn execute(&self, plan: PhysicalPlan, opts: &QueryOptions) -> Result<QueryResult> {
        let columns = plan
            .schema()
            .iter()
            .map(|f| Field::new(f.name.clone(), f.data_type.result_type()))
            .collect();
        let timeout = (opts.timeout_ms > 0).then(|| Duration::from_millis(opts.timeout_ms));
        let memory = usize::try_from(self.config.max_query_memory_mb.saturating_mul(1024 * 1024))
            .unwrap_or(usize::MAX);
        let ctx = ExecContext::new(timeout, memory, self.config.test_functions)
            .with_max_join_rows(self.config.max_join_rows)
            .with_physical_options(opts.physical());
        let mut root = build(plan);
        let mut rows = Vec::new();
        let mut row_count: u64 = 0;
        while let Some(row) = root.next(&ctx)? {
            row_count += 1;
            if let Some(max) = opts.max_rows
                && row_count > max
            {
                return Err(Error::resource_limit(format!(
                    "result exceeds max_rows = {max}"
                )));
            }
            if !opts.count_only {
                ctx.reserve(row.iter().map(|v| v.approx_size()).sum::<usize>() + 24)?;
                rows.push(row);
            }
        }
        Ok(QueryResult {
            columns,
            rows,
            row_count,
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
        let mut e = Engine::new(Config::default());
        e.load(LoadRequest {
            table: "t".into(),
            format: Format::Csv,
            source: Source::Data("id,name,amt\n1,a,1.5\n2,b,\n3,c,0.25\n".into()),
            schema: None,
            header: true,
            delimiter: b',',
            replace: false,
        })
        .unwrap();
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
}
