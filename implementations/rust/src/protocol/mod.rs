//! The JSON request/response protocol (protocol.md §3–§6), shared by the
//! `session` and `exec` CLI modes.

pub mod request;
pub mod session;

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::time::{Duration, Instant};

use crate::engine::Engine;
use crate::error::{Error, Result};
use crate::json::{self, Json};
use crate::storage::{Field, Table};
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

fn columns_json(fields: &[Field]) -> Json {
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

/// Handles one raw request line and returns the single-line response.
pub fn handle_line(engine: &mut Engine, line: &str) -> String {
    let resp = match json::parse(line) {
        Ok(v) => handle_json(engine, &v),
        Err(e) => error_response(
            Json::Null,
            &Error::invalid_request(format!("invalid JSON: {e}")),
        ),
    };
    resp.to_string_compact()
}

/// Handles one parsed request value, never panicking.
pub fn handle_json(engine: &mut Engine, req: &Json) -> Json {
    let id = req.get("id").cloned().unwrap_or(Json::Null);
    if !req.is_object() {
        return error_response(
            Json::Null,
            &Error::invalid_request("request must be a JSON object"),
        );
    }
    let started = Instant::now();
    let result = catch_unwind(AssertUnwindSafe(|| {
        Request::parse(req, engine.config.test_functions).and_then(|r| execute(engine, r, started))
    }));
    let result = match result {
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
    };
    match result {
        Ok(body) => with_id(id, body),
        Err(err) => error_response(id, &err),
    }
}

fn ok() -> (&'static str, Json) {
    ("ok", Json::Bool(true))
}

/// Executes a validated request, returning the success body (without id).
fn execute(engine: &mut Engine, req: Request, started: Instant) -> Result<Json> {
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
            body.push(("indexes", Json::Array(Vec::new())));
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
            let result = engine.query(&sql, &options)?;
            let mut body = vec![ok(), ("columns", columns_json(&result.columns))];
            if !options.count_only {
                let mut out = String::with_capacity(result.rows.len() * 16 + 2);
                out.push('[');
                for (i, row) in result.rows.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    out.push('[');
                    for (j, v) in row.iter().enumerate() {
                        if j > 0 {
                            out.push(',');
                        }
                        v.write_json(result.columns[j].data_type, &mut out);
                    }
                    out.push(']');
                }
                out.push(']');
                body.push(("rows", Json::Raw(out)));
            }
            body.push(("row_count", Json::uint(result.row_count)));
            body.push((
                "stats",
                Json::object(vec![(
                    "elapsed_us",
                    Json::uint(started.elapsed().as_micros() as u64),
                )]),
            ));
            body
        }
        Request::Explain { sql, options } => {
            vec![ok(), ("plan", engine.explain(&sql, &options)?)]
        }
        Request::Sleep { ms } => {
            std::thread::sleep(Duration::from_millis(ms));
            vec![ok()]
        }
    }))
}
