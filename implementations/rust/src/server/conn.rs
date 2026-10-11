//! One HTTP connection: reads requests (keep-alive), routes them to the
//! endpoints of protocol.md §7 and writes the responses.

use std::io::{BufReader, ErrorKind};
use std::net::TcpStream;
use std::sync::Arc;
use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

use super::Shared;
use super::http::{self, ReadError, Response};
use super::metrics;
use super::query::{self, Event, Job};
use crate::engine::QueryOptions;
use crate::error::{Error, ErrorCode, Result};
use crate::json::{self, Json};
use crate::log;
use crate::protocol::request::Request;
use crate::protocol::{
    capabilities_json, catch_panic, error_response, execute, request_id, respond, version_json,
};

/// How often a connection waiting for a query result checks whether the
/// client is still connected.
const DISCONNECT_POLL: Duration = Duration::from_millis(20);

/// What a handler did with the request.
enum Outcome {
    /// Send this response.
    Respond(Response),
    /// The response has been written.
    Written,
    /// The connection must be closed without a (further) response.
    Close,
}

/// Serves requests on one connection until it closes.
pub fn handle(shared: &Arc<Shared>, stream: TcpStream) {
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_nodelay(true);
    let Ok(read_half) = stream.try_clone() else {
        return;
    };
    let mut conn = Conn {
        shared: shared.clone(),
        stream,
    };
    let mut reader = BufReader::new(read_half);
    loop {
        let max_body = conn.shared.serve.max_request_bytes;
        let req = match http::read_request(&mut reader, &mut conn.stream, max_body) {
            Ok(Some(r)) => r,
            Ok(None) | Err(ReadError::Closed) => return,
            Err(ReadError::BadRequest(msg)) => {
                conn.reply_error(&Error::invalid_request(msg));
                return;
            }
            Err(ReadError::TooLarge) => {
                conn.reply_error(&Error::resource_limit(format!(
                    "request body exceeds --max-request-bytes = {max_body}"
                )));
                return;
            }
        };
        let shared = conn.shared.clone();
        let _active = shared.begin_request();
        shared.metrics.http_request();
        let started = Instant::now();
        let outcome = conn.route(&req);
        let keep_alive = req.keep_alive && !conn.shared.is_shutting_down();
        let status = match outcome {
            Outcome::Respond(resp) => {
                if http::write_response(&mut conn.stream, &resp, keep_alive).is_err() {
                    return;
                }
                Some(resp.status)
            }
            Outcome::Written => None,
            Outcome::Close => return,
        };
        log::debug(
            "http request",
            vec![
                ("method", Json::str(&req.method)),
                ("path", Json::String(format!("/{}", req.segments.join("/")))),
                (
                    "status",
                    status.map_or(Json::Null, |s| Json::uint(u64::from(s))),
                ),
                (
                    "duration_ms",
                    Json::uint(started.elapsed().as_millis() as u64),
                ),
            ],
        );
        if !keep_alive {
            return;
        }
    }
}

struct Conn {
    shared: Arc<Shared>,
    stream: TcpStream,
}

fn json_response(status: u16, body: &Json) -> Response {
    Response::json(status, body.to_string_compact())
}

/// The response for a protocol result: `ok_status` on success, else the
/// error's status (protocol.md §7.1).
fn protocol_response(id: Json, result: Result<Json>, ok_status: u16) -> Response {
    let status = match &result {
        Ok(_) => ok_status,
        Err(e) => e.code.http_status(),
    };
    json_response(status, &respond(id, result))
}

fn error_body(err: &Error) -> Response {
    json_response(err.code.http_status(), &error_response(Json::Null, err))
}

/// Parses a JSON request body that must be an object.
fn json_body(req: &http::Request) -> Result<Json> {
    let text = std::str::from_utf8(&req.body)
        .map_err(|_| Error::invalid_request("request body is not valid UTF-8"))?;
    let value =
        json::parse(text).map_err(|e| Error::invalid_request(format!("invalid JSON: {e}")))?;
    if !value.is_object() {
        return Err(Error::invalid_request("request body must be a JSON object"));
    }
    Ok(value)
}

/// `body` with its `op` member set to `op` (endpoint-specific requests).
fn with_op(body: Json, op: &str) -> Json {
    let Json::Object(mut fields) = body else {
        return body;
    };
    fields.retain(|(k, _)| k != "op");
    fields.insert(0, ("op".to_string(), Json::str(op)));
    Json::Object(fields)
}

/// A boolean query-string parameter.
fn bool_param(req: &http::Request, name: &str) -> Result<Option<bool>> {
    match req.param(name) {
        None => Ok(None),
        Some("true") | Some("1") => Ok(Some(true)),
        Some("false") | Some("0") => Ok(Some(false)),
        Some(v) => Err(Error::invalid_request(format!(
            "query parameter '{name}' must be true or false, got '{v}'"
        ))),
    }
}

impl Conn {
    fn reply_error(&mut self, err: &Error) {
        let _ = http::write_response(&mut self.stream, &error_body(err), false);
    }

    fn route(&mut self, req: &http::Request) -> Outcome {
        let segs: Vec<&str> = req.segments.iter().map(String::as_str).collect();
        let method = req.method.as_str();
        // Endpoints that stay available during shutdown.
        let always = matches!(
            segs.as_slice(),
            ["health"] | ["metrics"] | ["v1", "queries", ..]
        );
        let allowed: &[&str] = match segs.as_slice() {
            ["health"] | ["metrics"] | ["v1", "version"] | ["v1", "capabilities"] => &["GET"],
            ["v1", "query"] | ["v1", "query", "stream"] | ["v1", "explain"] | ["v1", "request"] => {
                &["POST"]
            }
            ["v1", "tables"] => &["GET"],
            ["v1", "tables", name] if !name.is_empty() => &["PUT", "DELETE"],
            ["v1", "tables", name, "schema" | "stats"] if !name.is_empty() => &["GET"],
            ["v1", "queries"] => &["GET"],
            ["v1", "queries", id] if !id.is_empty() => &["DELETE"],
            _ => {
                return Outcome::Respond(error_body(&Error::not_found(format!(
                    "no such endpoint: /{}",
                    req.segments.join("/")
                ))));
            }
        };
        if !allowed.contains(&method) {
            let err = Error::invalid_request(format!(
                "method {method} is not allowed here (allowed: {})",
                allowed.join(", ")
            ));
            let resp = error_body(&err);
            return Outcome::Respond(
                Response {
                    status: 405,
                    ..resp
                }
                .with_header("Allow", allowed.join(", ")),
            );
        }
        if !always && self.shared.is_shutting_down() {
            return Outcome::Respond(error_body(&Error::new(
                ErrorCode::ShuttingDown,
                "the server is shutting down",
            )));
        }
        match segs.as_slice() {
            ["health"] => Outcome::Respond(self.health()),
            ["metrics"] => {
                let text = self.shared.metrics.render(self.shared.gauges());
                Outcome::Respond(Response {
                    status: 200,
                    content_type: metrics::CONTENT_TYPE,
                    headers: Vec::new(),
                    body: text.into_bytes(),
                })
            }
            ["v1", "version"] => Outcome::Respond(json_response(200, &version_json())),
            ["v1", "capabilities"] => Outcome::Respond(json_response(200, &capabilities_json())),
            ["v1", "query"] => self.query_endpoint(req, false),
            ["v1", "query", "stream"] => self.query_endpoint(req, true),
            ["v1", "explain"] => match json_body(req) {
                Ok(body) => self.protocol_request(with_op(body, "explain"), 200),
                Err(e) => Outcome::Respond(error_body(&e)),
            },
            ["v1", "request"] => match json_body(req) {
                Ok(body) => self.protocol_request(body, 200),
                Err(e) => Outcome::Respond(error_body(&e)),
            },
            ["v1", "tables"] => {
                self.protocol_request(Json::object(vec![("op", Json::str("tables"))]), 200)
            }
            ["v1", "tables", name] if method == "PUT" => {
                Outcome::Respond(self.put_table(name, req))
            }
            ["v1", "tables", name] => self.protocol_request(table_op("drop", name), 200),
            ["v1", "tables", name, "schema"] => {
                self.protocol_request(table_op("schema", name), 200)
            }
            ["v1", "tables", name, "stats"] => self.protocol_request(table_op("stats", name), 200),
            ["v1", "queries"] => Outcome::Respond(self.list_queries()),
            ["v1", "queries", id] => Outcome::Respond(self.cancel_query(id)),
            _ => unreachable!("route table and dispatch disagree"),
        }
    }

    fn health(&self) -> Response {
        if self.shared.is_shutting_down() {
            json_response(
                503,
                &Json::object(vec![("status", Json::str("shutting_down"))]),
            )
        } else {
            json_response(200, &Json::object(vec![("status", Json::str("ok"))]))
        }
    }

    fn list_queries(&self) -> Response {
        let queries = self
            .shared
            .registry
            .list()
            .iter()
            .map(|h| {
                Json::object(vec![
                    ("query_id", Json::str(&h.id)),
                    ("state", Json::str(h.state())),
                    (
                        "elapsed_ms",
                        Json::uint(h.started.elapsed().as_millis() as u64),
                    ),
                ])
            })
            .collect();
        json_response(
            200,
            &Json::object(vec![
                ("ok", Json::Bool(true)),
                ("queries", Json::Array(queries)),
            ]),
        )
    }

    fn cancel_query(&self, id: &str) -> Response {
        if self.shared.registry.cancel(id) {
            log::info("query cancel requested", vec![("query_id", Json::str(id))]);
            json_response(
                200,
                &Json::object(vec![
                    ("ok", Json::Bool(true)),
                    ("cancelled", Json::Bool(true)),
                ]),
            )
        } else {
            error_body(&Error::not_found(format!(
                "no queued or running query with id '{id}'"
            )))
        }
    }

    /// `PUT /v1/tables/{name}?format=…`: loads the body as a table.
    fn put_table(&self, name: &str, req: &http::Request) -> Response {
        let result = (|| {
            let mut options = vec![];
            if let Some(h) = bool_param(req, "header")? {
                options.push(("header", Json::Bool(h)));
            }
            if let Some(d) = req.param("delimiter") {
                options.push(("delimiter", Json::str(d)));
            }
            if let Some(l) = req.param("layout") {
                options.push(("layout", Json::str(l)));
            }
            let mut fields = vec![
                ("op", Json::str("load")),
                ("table", Json::str(name)),
                ("format", req.param("format").map_or(Json::Null, Json::str)),
                ("data", Json::str("")),
                ("options", Json::object(options)),
            ];
            if let Some(r) = bool_param(req, "replace")? {
                fields.push(("replace", Json::Bool(r)));
            }
            if let Some(schema) = req.param("schema") {
                let parsed = json::parse(schema).map_err(|e| {
                    Error::invalid_request(format!("query parameter 'schema': invalid JSON: {e}"))
                })?;
                fields.push(("schema", parsed));
            }
            let Request::Load(mut load) = Request::parse(
                &Json::object(fields),
                self.shared.engine.config.test_functions,
            )?
            else {
                unreachable!("a load request parses as a load");
            };
            let data = String::from_utf8(req.body.clone())
                .map_err(|_| Error::ingest("request body is not valid UTF-8"))?;
            load.source = crate::engine::Source::Data(data);
            execute(&self.shared.engine, Request::Load(load), Instant::now())
        })();
        protocol_response(Json::Null, catch_panic(|| result), 201)
    }

    /// Executes a protocol request object (`/v1/request` and the REST
    /// endpoints mapped onto protocol ops). Queries go through admission.
    fn protocol_request(&mut self, body: Json, ok_status: u16) -> Outcome {
        let id = request_id(&body);
        let shared = self.shared.clone();
        let parsed = Request::parse(&body, shared.engine.config.test_functions);
        match parsed {
            Ok(Request::Query { sql, options }) => self.run_query(id, sql, options, false),
            Ok(other) => {
                let result = catch_panic(|| execute(&shared.engine, other, Instant::now()));
                Outcome::Respond(protocol_response(id, result, ok_status))
            }
            Err(e) => Outcome::Respond(protocol_response(id, Err(e), ok_status)),
        }
    }

    /// `POST /v1/query` and `POST /v1/query/stream`.
    fn query_endpoint(&mut self, req: &http::Request, stream: bool) -> Outcome {
        let body = match json_body(req) {
            Ok(b) => with_op(b, "query"),
            Err(e) => return Outcome::Respond(error_body(&e)),
        };
        let id = request_id(&body);
        match Request::parse(&body, self.shared.engine.config.test_functions) {
            Ok(Request::Query { sql, options }) => self.run_query(id, sql, options, stream),
            Ok(_) => unreachable!("a query request parses as a query"),
            Err(e) => Outcome::Respond(protocol_response(id, Err(e), 200)),
        }
    }

    /// Admits, registers and runs a query, relaying its result.
    fn run_query(&mut self, id: Json, sql: String, options: QueryOptions, stream: bool) -> Outcome {
        let shared = self.shared.clone();
        let arrival = Instant::now();
        let handle = match shared.registry.register(options.query_id.as_deref()) {
            Ok(h) => h,
            Err(e) => {
                shared
                    .metrics
                    .query_finished(Some(e.code), arrival.elapsed());
                let qid = options.query_id.clone().unwrap_or_default();
                return Outcome::Respond(
                    protocol_response(id, Err(e), 200).with_header("X-PolyQuery-Query-Id", qid),
                );
            }
        };
        let qid_header = ("X-PolyQuery-Query-Id", handle.id.clone());
        let ticket = match shared.admission.enter() {
            Ok(t) => t,
            Err(e) => {
                shared.registry.unregister(&handle);
                shared
                    .metrics
                    .query_finished(Some(e.code), arrival.elapsed());
                query::log_completion(&handle.id, Some(e.code), arrival.elapsed(), 0);
                return Outcome::Respond(
                    protocol_response(id, Err(e), 200).with_header(qid_header.0, qid_header.1),
                );
            }
        };
        log::debug(
            "query started",
            vec![
                ("query_id", Json::str(&handle.id)),
                ("sql", Json::str(&sql)),
            ],
        );
        let job = Job {
            shared: shared.clone(),
            handle: handle.clone(),
            id,
            sql,
            options,
            arrival,
            stream,
        };
        let rx = match query::spawn(job, ticket) {
            Ok(rx) => rx,
            Err(e) => {
                shared.admission.abandon(ticket);
                shared.registry.unregister(&handle);
                let err = Error::internal(format!("cannot start query thread: {e}"));
                shared
                    .metrics
                    .query_finished(Some(err.code), arrival.elapsed());
                return Outcome::Respond(error_body(&err).with_header(qid_header.0, qid_header.1));
            }
        };
        let mut streaming = false;
        loop {
            match rx.recv_timeout(DISCONNECT_POLL) {
                Ok(Event::Response { status, body }) => {
                    return Outcome::Respond(
                        Response::json(status, body).with_header(qid_header.0, qid_header.1),
                    );
                }
                Ok(Event::Line(line)) => {
                    let mut written = Ok(());
                    if !streaming {
                        streaming = true;
                        written = http::write_chunked_head(
                            &mut self.stream,
                            200,
                            "application/x-ndjson",
                            std::slice::from_ref(&qid_header),
                            !shared.is_shutting_down(),
                        );
                    }
                    if written
                        .and_then(|_| http::write_chunk(&mut self.stream, line.as_bytes()))
                        .is_err()
                    {
                        handle.request_cancel();
                        return Outcome::Close;
                    }
                }
                Ok(Event::Last(line)) => {
                    let done = http::write_chunk(&mut self.stream, line.as_bytes())
                        .and_then(|_| http::write_last_chunk(&mut self.stream));
                    return if done.is_ok() {
                        Outcome::Written
                    } else {
                        Outcome::Close
                    };
                }
                Err(RecvTimeoutError::Timeout) => {
                    if client_gone(&self.stream) {
                        log::info(
                            "client disconnected; cancelling query",
                            vec![("query_id", Json::str(&handle.id))],
                        );
                        handle.request_cancel();
                        return Outcome::Close;
                    }
                }
                Err(RecvTimeoutError::Disconnected) => {
                    // The execution thread ended without reporting (it never
                    // panics outside `catch_panic`, so this is defensive).
                    if streaming {
                        return Outcome::Close;
                    }
                    let err = Error::internal("query execution ended unexpectedly");
                    return Outcome::Respond(
                        error_body(&err).with_header(qid_header.0, qid_header.1),
                    );
                }
            }
        }
    }
}

fn table_op(op: &str, name: &str) -> Json {
    Json::object(vec![("op", Json::str(op)), ("table", Json::str(name))])
}

/// Whether the client has closed the connection (EOF or error), checked
/// without consuming any pipelined request bytes.
fn client_gone(stream: &TcpStream) -> bool {
    if stream.set_nonblocking(true).is_err() {
        return true;
    }
    let mut buf = [0u8; 1];
    let gone = match stream.peek(&mut buf) {
        Ok(0) => true,
        Ok(_) => false,
        Err(e) => !matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted),
    };
    let _ = stream.set_nonblocking(false);
    gone
}
