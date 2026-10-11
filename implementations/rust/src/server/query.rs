//! Query execution for the HTTP server: admission, the per-query execution
//! thread, timeouts/cancellation, and NDJSON streaming with backpressure
//! (protocol.md §7.2, concurrency.md §2–§4).
//!
//! The connection thread admits and registers a query, then hands it to an
//! execution thread and waits for [`Event`]s on a bounded channel, polling the
//! client socket for disconnects meanwhile. The execution thread waits for a
//! worker slot, runs the query against a catalog snapshot and reports the
//! outcome. A full channel blocks the producer (re-checking timeout and
//! cancellation), so a client that stops reading stops the query.

use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::time::{Duration, Instant};

use super::Shared;
use super::admission::Ticket;
use super::registry::QueryHandle;
use crate::engine::{QueryControl, QueryCursor, QueryOptions, QueryResult};
use crate::error::{Error, ErrorCode, Result};
use crate::json::Json;
use crate::log;
use crate::protocol::{catch_panic, columns_json, error_response, query_body, respond, write_row};
use crate::types::DataType;

/// Streamed rows per `rows` line (protocol limit: 10,000).
const BATCH_ROWS: usize = 4096;
/// A `rows` line is flushed once it reaches this many bytes …
const BATCH_BYTES: usize = 1 << 20;
/// … or once its first row is this old.
const BATCH_AGE: Duration = Duration::from_millis(100);
/// Lines buffered between the execution and connection threads (≤ 16).
const CHANNEL_LINES: usize = 8;
/// Back-off while the channel is full.
const FULL_BACKOFF: Duration = Duration::from_millis(2);

/// What the execution thread reports to the connection thread.
#[derive(Debug)]
pub enum Event {
    /// A complete, non-streamed response (also errors before a stream header).
    Response { status: u16, body: String },
    /// A streamed NDJSON line; the first one is the header.
    Line(String),
    /// The final streamed line (`end` or `error`).
    Last(String),
}

/// A query accepted for execution.
pub struct Job {
    pub shared: Arc<Shared>,
    pub handle: Arc<QueryHandle>,
    /// The request `id` echoed in non-streamed responses.
    pub id: Json,
    pub sql: String,
    pub options: QueryOptions,
    pub arrival: Instant,
    pub stream: bool,
}

/// Effective deadline: `options.timeout_ms`, else the server default; time
/// spent queued counts (concurrency.md §3).
pub fn deadline(
    arrival: Instant,
    options: &QueryOptions,
    server_timeout_ms: u64,
) -> Option<Instant> {
    let ms = if options.timeout_ms > 0 {
        options.timeout_ms
    } else {
        server_timeout_ms
    };
    (ms > 0).then(|| arrival + Duration::from_millis(ms))
}

/// Starts the execution thread; events arrive on the returned receiver.
pub fn spawn(job: Job, ticket: Ticket) -> std::io::Result<Receiver<Event>> {
    let (tx, rx) = mpsc::sync_channel(CHANNEL_LINES);
    std::thread::Builder::new()
        .name(format!("query-{}", job.handle.id))
        .stack_size(crate::protocol::WORKER_STACK_BYTES)
        .spawn(move || run(job, ticket, tx))?;
    Ok(rx)
}

/// Successful outcome of a query.
enum Success {
    /// Non-streamed: the materialized result.
    Result(QueryResult),
    /// Streamed: rows sent.
    Streamed(u64),
}

/// Error outcome; `header_sent` tells whether a stream already started.
struct Failure {
    error: Error,
    header_sent: bool,
    rows: u64,
}

fn run(job: Job, ticket: Ticket, tx: SyncSender<Event>) {
    let shared = job.shared.clone();
    let deadline = deadline(
        job.arrival,
        &job.options,
        shared.engine.config.query_timeout_ms,
    );
    let mut header_sent = false;
    let mut rows_sent = 0u64;
    let outcome = {
        let stop = || interrupted(&job.handle, deadline);
        match shared.admission.wait(ticket, stop) {
            Err(error) => Err(error),
            Ok(_permit) => {
                job.handle.set_running();
                catch_panic(|| {
                    let control = QueryControl {
                        deadline,
                        cancel: Some(job.handle.cancel.clone()),
                    };
                    let cursor = shared.engine.start_query(&job.sql, &job.options, control)?;
                    if job.stream {
                        let mut s = Streamer {
                            tx: &tx,
                            query_id: &job.handle.id,
                            count_only: job.options.count_only,
                            header_sent: &mut header_sent,
                            rows_sent: &mut rows_sent,
                        };
                        s.run(cursor).map(Success::Streamed)
                    } else {
                        cursor
                            .collect_json(job.options.count_only)
                            .map(Success::Result)
                    }
                })
                // `_permit` is released here, before the response is sent.
            }
        }
    };
    let outcome = outcome.map_err(|error| Failure {
        error,
        header_sent,
        rows: rows_sent,
    });
    finish(&job, outcome, &tx);
}

/// TIMEOUT / CANCELLED checks for a query that is not executing operators.
fn interrupted(handle: &QueryHandle, deadline: Option<Instant>) -> Result<()> {
    if handle.is_cancelled() {
        return Err(Error::new(ErrorCode::Cancelled, "query was cancelled"));
    }
    if deadline.is_some_and(|d| Instant::now() >= d) {
        return Err(Error::new(ErrorCode::Timeout, "query exceeded its timeout"));
    }
    Ok(())
}

/// Records metrics, unregisters the query, logs, and sends the final event.
fn finish(job: &Job, outcome: std::result::Result<Success, Failure>, tx: &SyncSender<Event>) {
    let shared = &job.shared;
    let duration = job.arrival.elapsed();
    let (code, rows) = match &outcome {
        Ok(Success::Result(r)) => (None, r.row_count),
        Ok(Success::Streamed(n)) => (None, *n),
        Err(f) => (Some(f.error.code), f.rows),
    };
    shared.metrics.query_finished(code, duration);
    // Unregister before responding: once the client has the response, the
    // query id is free and cancelling it is NOT_FOUND.
    shared.registry.unregister(&job.handle);
    log_completion(&job.handle.id, code, duration, rows);
    let event = match outcome {
        Ok(Success::Result(result)) => Event::Response {
            status: 200,
            body: respond(
                job.id.clone(),
                Ok(query_body(result, job.options.count_only, duration)),
            )
            .to_string_compact(),
        },
        Ok(Success::Streamed(n)) => {
            Event::Last(format!("{{\"type\":\"end\",\"row_count\":{n}}}\n"))
        }
        Err(f) if f.header_sent => Event::Last(
            Json::object(vec![
                ("type", Json::str("error")),
                ("error", f.error.to_json()),
            ])
            .to_string_compact()
                + "\n",
        ),
        Err(f) => Event::Response {
            status: f.error.code.http_status(),
            body: error_response(job.id.clone(), &f.error).to_string_compact(),
        },
    };
    // The receiver is gone if the client disconnected; nothing to do then.
    let _ = tx.send(event);
}

pub fn log_completion(query_id: &str, code: Option<ErrorCode>, duration: Duration, rows: u64) {
    let mut fields = vec![
        ("query_id", Json::str(query_id)),
        (
            "status",
            Json::str(if code.is_none() { "ok" } else { "error" }),
        ),
        (
            "duration_ms",
            Json::Raw(format!("{:.3}", duration.as_secs_f64() * 1000.0)),
        ),
        ("rows", Json::uint(rows)),
    ];
    if let Some(c) = code {
        fields.push(("error_code", Json::str(c.as_str())));
    }
    log::info("query finished", fields);
}

/// Produces the NDJSON stream of one query.
struct Streamer<'a> {
    tx: &'a SyncSender<Event>,
    query_id: &'a str,
    count_only: bool,
    header_sent: &'a mut bool,
    rows_sent: &'a mut u64,
}

impl Streamer<'_> {
    fn run(&mut self, mut cursor: QueryCursor) -> Result<u64> {
        let header = Json::object(vec![
            ("type", Json::str("header")),
            ("query_id", Json::str(self.query_id)),
            ("columns", columns_json(cursor.columns())),
        ])
        .to_string_compact()
            + "\n";
        // The header is held back until the first batch (or the end) is
        // ready, so errors found early still get a proper HTTP status.
        let mut header = Some(header);
        let types: Vec<DataType> = cursor.columns().iter().map(|f| f.data_type).collect();
        let mut batch = String::new();
        let mut batch_rows = 0usize;
        let mut batch_started = Instant::now();
        while let Some(row) = cursor.next_row()? {
            if self.count_only {
                continue;
            }
            if batch_rows == 0 {
                batch.push_str("{\"type\":\"rows\",\"rows\":[");
                batch_started = Instant::now();
            } else {
                batch.push(',');
            }
            write_row(&row, &types, &mut batch);
            batch_rows += 1;
            // The first row goes out at once so that slow queries show
            // progress; later batches fill up or age out.
            if *self.rows_sent == 0
                || batch_rows >= BATCH_ROWS
                || batch.len() >= BATCH_BYTES
                || batch_started.elapsed() >= BATCH_AGE
            {
                batch.push_str("]}\n");
                self.send_header(&mut header, &cursor)?;
                self.send(Event::Line(std::mem::take(&mut batch)), &cursor)?;
                *self.rows_sent += batch_rows as u64;
                batch_rows = 0;
            }
        }
        self.send_header(&mut header, &cursor)?;
        if batch_rows > 0 {
            batch.push_str("]}\n");
            self.send(Event::Line(batch), &cursor)?;
            *self.rows_sent += batch_rows as u64;
        }
        Ok(cursor.row_count())
    }

    fn send_header(&mut self, header: &mut Option<String>, cursor: &QueryCursor) -> Result<()> {
        if let Some(h) = header.take() {
            self.send(Event::Line(h), cursor)?;
            *self.header_sent = true;
        }
        Ok(())
    }

    /// Sends a line, blocking while the client is behind (backpressure) but
    /// still observing the query's timeout and cancellation.
    fn send(&self, event: Event, cursor: &QueryCursor) -> Result<()> {
        let mut event = event;
        loop {
            match self.tx.try_send(event) {
                Ok(()) => return Ok(()),
                Err(TrySendError::Full(e)) => {
                    cursor.check_interrupt()?;
                    event = e;
                    std::thread::sleep(FULL_BACKOFF);
                }
                Err(TrySendError::Disconnected(_)) => {
                    return Err(Error::new(ErrorCode::Cancelled, "client disconnected"));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::engine::{Engine, LoadRequest, Source};
    use crate::ingest::Format;
    use crate::storage::Layout;
    use std::sync::atomic::{AtomicBool, Ordering};

    fn engine(rows: usize) -> Engine {
        let e = Engine::new(Config::default());
        let mut csv = String::from("n\n");
        for i in 0..rows {
            csv.push_str(&format!("{i}\n"));
        }
        e.load(LoadRequest {
            table: "t".into(),
            format: Format::Csv,
            source: Source::Data(csv),
            schema: None,
            header: true,
            delimiter: b',',
            replace: false,
            layout: Layout::Column,
            dictionary: None,
        })
        .unwrap();
        e
    }

    fn stream(e: &Engine, cancel: Arc<AtomicBool>, tx: SyncSender<Event>) -> (Result<u64>, bool) {
        let control = QueryControl {
            deadline: None,
            cancel: Some(cancel),
        };
        let cursor = e
            .start_query("SELECT n FROM t", &QueryOptions::default(), control)
            .unwrap();
        let (mut header_sent, mut rows_sent) = (false, 0);
        let mut s = Streamer {
            tx: &tx,
            query_id: "q",
            count_only: false,
            header_sent: &mut header_sent,
            rows_sent: &mut rows_sent,
        };
        let r = s.run(cursor);
        (r, header_sent)
    }

    #[test]
    fn streams_all_rows_in_bounded_batches() {
        let e = engine(10_000);
        let (tx, rx) = mpsc::sync_channel(CHANNEL_LINES);
        let reader = std::thread::spawn(move || rx.iter().collect::<Vec<_>>());
        let (r, header_sent) = stream(&e, Arc::new(AtomicBool::new(false)), tx);
        assert_eq!(r.unwrap(), 10_000);
        assert!(header_sent);
        let events = reader.join().unwrap();
        let Event::Line(header) = &events[0] else {
            panic!("no header")
        };
        assert!(header.starts_with(r#"{"type":"header","query_id":"q","columns":[{"name":"n""#));
        let rows: usize = events[1..]
            .iter()
            .map(|ev| match ev {
                Event::Line(l) => l.matches("],[").count() + 1,
                _ => panic!("unexpected event"),
            })
            .sum();
        assert_eq!(rows, 10_000);
    }

    #[test]
    fn blocks_when_client_does_not_read() {
        let e = Arc::new(engine(200_000));
        let (tx, rx) = mpsc::sync_channel(CHANNEL_LINES);
        let cancel = Arc::new(AtomicBool::new(false));
        let producer = {
            let (e, cancel) = (e.clone(), cancel.clone());
            std::thread::spawn(move || stream(&e, cancel, tx).0)
        };
        std::thread::sleep(Duration::from_millis(300));
        // Execution is blocked on the full channel, not finished.
        assert!(!producer.is_finished());
        cancel.store(true, Ordering::Relaxed);
        let err = producer.join().unwrap().unwrap_err();
        assert_eq!(err.code, ErrorCode::Cancelled);
        assert_eq!(rx.try_iter().count(), CHANNEL_LINES);
    }
}
