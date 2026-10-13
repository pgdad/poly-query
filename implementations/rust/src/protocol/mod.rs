//! The JSON request/response protocol (protocol.md §3–§6), shared by the
//! `session` and `exec` CLI modes.

pub mod request;
pub mod session;

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::time::{Duration, Instant};

use crate::engine::{Engine, QueryControl, QueryResult};
use crate::error::{Error, Result};
use crate::exec::Row;
use crate::json::{self, Json};
use crate::storage::{ColumnStats, Field, Table};
use crate::types::DataType;
use request::Request;

pub const ENGINE_NAME: &str = "polyquery-rust";
pub const ENGINE_VERSION: &str = env!("CARGO_PKG_VERSION");
pub const PROTOCOL_VERSION: i64 = 1;
pub const SPEC_VERSION: &str = "1.0.0";

/// Capability strings claimed by this engine (phases/README.md).
pub const CAPABILITIES: &[&str] = &[
    "phase1",
    "ingest.csv",
    "ingest.json",
    "ingest.jsonl",
    "sql.basic",
    "test.functions",
    "phase2",
    "sql.groupby",
    "sql.join",
    "sql.functions",
    "sql.subquery",
    "sql.cte",
    "sql.correlated_subquery",
    "phase3",
    "storage.pqcf",
    "storage.mmap",
    "index.hash",
    "index.btree",
    "phase4",
    "http.streaming",
    "phase5",
    "exec.row",
    "exec.vectorized",
    "exec.parallel",
    "join.hash",
    "join.merge",
    "join.nested_loop",
    "native.kernels",
    "change.union_all",
    "change.decimal38",
    "change.expression_limits",
];

/// The `version` response body (without id).
pub fn version_json() -> Json {
    Json::object(vec![
        ("ok", Json::Bool(true)),
        ("engine", Json::str(ENGINE_NAME)),
        ("engine_version", Json::str(ENGINE_VERSION)),
        ("language", Json::str("rust")),
        ("protocol_version", Json::int(PROTOCOL_VERSION)),
        ("spec_version", Json::str(SPEC_VERSION)),
        ("runtime", Json::str(env!("PQ_RUSTC_VERSION"))),
        (
            "build",
            Json::object(vec![
                ("profile", Json::str(env!("PQ_BUILD_PROFILE"))),
                ("flags", Json::str(env!("PQ_BUILD_FLAGS"))),
            ]),
        ),
    ])
}

/// The `capabilities` response body (without id).
pub fn capabilities_json() -> Json {
    Json::object(vec![
        ("ok", Json::Bool(true)),
        ("protocol_version", Json::int(PROTOCOL_VERSION)),
        (
            "capabilities",
            Json::Array(CAPABILITIES.iter().map(|c| Json::str(c)).collect()),
        ),
    ])
}

pub fn columns_json(fields: &[Field]) -> Json {
    Json::Array(
        fields
            .iter()
            .map(|f| {
                Json::object(vec![
                    ("name", Json::str(&f.name)),
                    ("type", Json::String(f.data_type.name())),
                ])
            })
            .collect(),
    )
}

fn table_json(t: &Table) -> Vec<(&'static str, Json)> {
    vec![
        ("table", Json::str(&t.name)),
        ("row_count", Json::uint(t.row_count as u64)),
        ("columns", columns_json(&t.fields)),
    ]
}

fn value_json(v: &Option<crate::types::Value>, f: &Field) -> Json {
    match v {
        None => Json::Null,
        Some(v) => {
            let mut s = String::new();
            v.write_json(f.data_type, &mut s);
            Json::Raw(s)
        }
    }
}

fn column_stats_json(f: &Field, s: &ColumnStats) -> Json {
    Json::object(vec![
        ("name", Json::str(&f.name)),
        ("type", Json::String(f.data_type.name())),
        ("null_count", Json::uint(s.null_count as u64)),
        ("distinct_count", Json::uint(s.distinct_count as u64)),
        ("min", value_json(&s.min, f)),
        ("max", value_json(&s.max, f)),
    ])
}

/// Prefixes a response body object with the request id.
fn with_id(id: Json, body: Json) -> Json {
    let mut fields = vec![("id".to_string(), id)];
    if let Json::Object(rest) = body {
        fields.extend(rest);
    }
    Json::Object(fields)
}

/// Builds an error response.
pub fn error_response(id: Json, err: &Error) -> Json {
    with_id(
        id,
        Json::object(vec![("ok", Json::Bool(false)), ("error", err.to_json())]),
    )
}

/// Handles one raw request line, received at `received`, and returns the
/// single-line response.
pub fn handle_line(engine: &Engine, line: &str, received: Instant) -> String {
    let resp = match json::parse(line) {
        Ok(v) => handle_json(engine, &v, received),
        Err(e) => error_response(
            Json::Null,
            &Error::invalid_request(format!("invalid JSON: {e}")),
        ),
    };
    resp.to_string_compact()
}

/// Handles one parsed request value, received at `received` (the query
/// timeout counts from then), never panicking.
pub fn handle_json(engine: &Engine, req: &Json, received: Instant) -> Json {
    let id = request_id(req);
    if !req.is_object() {
        return error_response(
            Json::Null,
            &Error::invalid_request("request must be a JSON object"),
        );
    }
    let result = catch_panic(|| {
        Request::parse(req, engine.config.test_functions).and_then(|r| execute(engine, r, received))
    });
    respond(id, result)
}

/// The `id` of a request object (`null` if absent).
pub fn request_id(req: &Json) -> Json {
    req.get("id").cloned().unwrap_or(Json::Null)
}

/// Builds the response object for a request result.
pub fn respond(id: Json, result: Result<Json>) -> Json {
    match result {
        Ok(body) => with_id(id, body),
        Err(err) => error_response(id, &err),
    }
}

/// Runs `f`, turning a panic into an `INTERNAL_ERROR` (logged).
pub fn catch_panic<T>(f: impl FnOnce() -> Result<T>) -> Result<T> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(panic) => {
            let msg = panic
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_else(|| "unknown panic".to_string());
            crate::log::error("internal error", vec![("detail", Json::String(msg))]);
            Err(Error::internal(
                "internal error while processing the request",
            ))
        }
    }
}

/// Serializes rows as a JSON array of arrays (types.md §9).
pub fn rows_json(rows: &[Row], columns: &[Field]) -> String {
    let types: Vec<DataType> = columns.iter().map(|f| f.data_type).collect();
    let mut out = String::with_capacity(rows.len() * 16 + 2);
    out.push('[');
    for (i, row) in rows.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        write_row(row, &types, &mut out);
    }
    out.push(']');
    out
}

/// Serializes one row as a JSON array (`types`: the column types).
pub fn write_row(row: &Row, types: &[DataType], out: &mut String) {
    out.push('[');
    for (j, v) in row.iter().enumerate() {
        if j > 0 {
            out.push(',');
        }
        v.write_json(types[j], out);
    }
    out.push(']');
}

/// The success body of a `query` request (protocol.md §5.2).
pub fn query_body(result: QueryResult, count_only: bool, elapsed: Duration) -> Json {
    let mut body = vec![ok(), ("columns", columns_json(&result.columns))];
    if !count_only {
        let rows = match result.rows_json {
            Some(json) => json,
            None => rows_json(&result.rows, &result.columns),
        };
        body.push(("rows", Json::Raw(rows)));
    }
    body.push(("row_count", Json::uint(result.row_count)));
    body.push((
        "stats",
        Json::object(vec![("elapsed_us", Json::uint(elapsed.as_micros() as u64))]),
    ));
    Json::object(body)
}

fn ok() -> (&'static str, Json) {
    ("ok", Json::Bool(true))
}

/// Executes a validated request, returning the success body (without id).
pub fn execute(engine: &Engine, req: Request, started: Instant) -> Result<Json> {
    Ok(Json::object(match req {
        Request::Version => return Ok(version_json()),
        Request::Capabilities => return Ok(capabilities_json()),
        Request::Tables => {
            let tables = engine
                .catalog()
                .tables()
                .map(|t| {
                    Json::object(vec![
                        ("name", Json::str(&t.name)),
                        ("row_count", Json::uint(t.row_count as u64)),
                    ])
                })
                .collect();
            vec![ok(), ("tables", Json::Array(tables))]
        }
        Request::Schema { table } => {
            let t = engine.table(&table)?;
            let mut body = vec![ok()];
            body.extend(table_json(&t));
            let indexes = engine
                .indexes(&t)
                .iter()
                .map(|ix| {
                    Json::object(vec![
                        ("name", Json::str(&ix.name)),
                        ("column", Json::str(ix.column_name())),
                        ("kind", Json::str(ix.kind.name())),
                    ])
                })
                .collect();
            body.push(("indexes", Json::Array(indexes)));
            body.push(("layout", Json::str(t.layout().name())));
            body
        }
        Request::Stats { table } => {
            let (t, stats) = engine.stats(&table)?;
            let columns = t
                .fields
                .iter()
                .zip(&stats.columns)
                .map(|(f, s)| column_stats_json(f, s))
                .collect();
            vec![
                ok(),
                ("table", Json::str(&t.name)),
                ("row_count", Json::uint(stats.row_count as u64)),
                ("columns", Json::Array(columns)),
            ]
        }
        Request::Save(save) => {
            let bytes = engine.save(&save)?;
            crate::log::info(
                "table saved",
                vec![
                    ("table", Json::str(&save.table)),
                    ("bytes", Json::uint(bytes)),
                ],
            );
            vec![
                ok(),
                ("path", Json::str(&save.path)),
                ("bytes", Json::uint(bytes)),
            ]
        }
        Request::Open(open) => {
            let t = engine.open(&open)?;
            crate::log::info(
                "table opened",
                vec![
                    ("table", Json::str(&t.name)),
                    ("rows", Json::uint(t.row_count as u64)),
                ],
            );
            let mut body = vec![ok()];
            body.extend(table_json(&t));
            body
        }
        Request::Drop { table } => {
            engine.drop_table(&table)?;
            vec![ok()]
        }
        Request::Reset => {
            engine.reset();
            vec![ok()]
        }
        Request::Load(load) => {
            let t = engine.load(load)?;
            crate::log::info(
                "table loaded",
                vec![
                    ("table", Json::str(&t.name)),
                    ("rows", Json::uint(t.row_count as u64)),
                ],
            );
            let mut body = vec![ok()];
            body.extend(table_json(&t));
            body
        }
        Request::Query { sql, options } => {
            let control = QueryControl {
                deadline: engine.deadline(started, &options),
                cancel: None,
            };
            let result = engine
                .start_query(&sql, &options, control)?
                .collect_json(options.count_only)?;
            return Ok(query_body(result, options.count_only, started.elapsed()));
        }
        Request::Explain { sql, options } => {
            let control = QueryControl {
                deadline: engine.deadline(started, &options),
                cancel: None,
            };
            vec![ok(), ("plan", engine.explain(&sql, &options, control)?)]
        }
        Request::Sleep { ms } => {
            std::thread::sleep(Duration::from_millis(ms));
            vec![ok()]
        }
    }))
}
