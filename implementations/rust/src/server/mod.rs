//! `serve`: the HTTP/1.1 server (protocol.md §7, concurrency.md).
//!
//! * One thread per connection reads requests (keep-alive supported) and
//!   routes them ([`conn`]).
//! * Queries are admitted by [`admission`] (worker limit + bounded FIFO
//!   queue), registered in [`registry`] by `query_id`, and executed on their
//!   own threads ([`query`]); other operations run on the connection thread.
//! * The engine's catalog is snapshot-based, so readers never block each
//!   other and mutations are atomic.
//! * SIGTERM/SIGINT ([`signal`]) trigger the graceful shutdown of
//!   concurrency.md §5.

pub mod admission;
mod conn;
pub mod http;
pub mod metrics;
mod query;
pub mod registry;
mod signal;

use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use crate::config::{Config, ServeConfig};
use crate::engine::Engine;
use crate::json::Json;
use crate::log;
use admission::Admission;
use metrics::{Gauges, Metrics};
use registry::Registry;

/// How often the main thread checks for a shutdown request.
const SIGNAL_POLL: Duration = Duration::from_millis(5);
/// Pause after a failed `accept` (e.g. out of file descriptors).
const ACCEPT_BACKOFF: Duration = Duration::from_millis(10);
/// After the grace period, how long cancelled requests get to answer.
const CANCEL_DRAIN: Duration = Duration::from_millis(1000);

/// State shared by all connections.
pub struct Shared {
    pub engine: Engine,
    pub serve: ServeConfig,
    pub admission: Admission,
    pub registry: Registry,
    pub metrics: Metrics,
    shutting_down: AtomicBool,
    /// Requests currently being processed (graceful shutdown waits for them).
    active: AtomicUsize,
}

impl Shared {
    pub fn is_shutting_down(&self) -> bool {
        self.shutting_down.load(Ordering::SeqCst)
    }

    pub fn gauges(&self) -> Gauges {
        Gauges {
            in_flight: self.admission.running(),
            queued: self.admission.queued(),
            tables: self.engine.catalog().len(),
        }
    }

    /// Marks a request as in progress until the guard is dropped.
    pub fn begin_request(&self) -> ActiveGuard<'_> {
        self.active.fetch_add(1, Ordering::SeqCst);
        ActiveGuard { shared: self }
    }

    fn active(&self) -> usize {
        self.active.load(Ordering::SeqCst)
    }
}

pub struct ActiveGuard<'a> {
    shared: &'a Shared,
}

impl Drop for ActiveGuard<'_> {
    fn drop(&mut self) {
        self.shared.active.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Runs the server until SIGTERM/SIGINT. Returns the process exit status.
pub fn serve(config: Config, serve: ServeConfig) -> u8 {
    let port = serve.port.unwrap_or(0);
    let listener = match TcpListener::bind((serve.host.as_str(), port)) {
        Ok(l) => l,
        Err(e) => {
            log::error(
                "cannot listen",
                vec![
                    ("host", Json::str(&serve.host)),
                    ("port", Json::uint(u64::from(port))),
                    ("detail", Json::String(e.to_string())),
                ],
            );
            return 1;
        }
    };
    let addr = match listener.local_addr() {
        Ok(a) => a,
        Err(e) => {
            log::error(
                "cannot listen",
                vec![("detail", Json::String(e.to_string()))],
            );
            return 1;
        }
    };
    signal::install();
    let workers = serve.workers.unwrap_or_else(|| {
        std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1)
    });
    let shared = Arc::new(Shared {
        engine: Engine::new(config),
        admission: Admission::new(workers, serve.queue_depth),
        registry: Registry::default(),
        metrics: Metrics::default(),
        serve,
        shutting_down: AtomicBool::new(false),
        active: AtomicUsize::new(0),
    });
    let host = addr.ip().to_string();
    let line = Json::object(vec![
        ("event", Json::str("listening")),
        ("host", Json::str(&host)),
        ("port", Json::uint(u64::from(addr.port()))),
    ])
    .to_string_compact();
    {
        let mut out = std::io::stdout().lock();
        if writeln!(out, "{line}").and_then(|_| out.flush()).is_err() {
            return 1;
        }
    }
    log::info(
        "server listening",
        vec![
            ("host", Json::str(&host)),
            ("port", Json::uint(u64::from(addr.port()))),
            ("workers", Json::uint(workers as u64)),
            ("queue_depth", Json::uint(shared.serve.queue_depth as u64)),
        ],
    );
    {
        let shared = shared.clone();
        let spawned = std::thread::Builder::new()
            .name("http-accept".into())
            .spawn(move || accept_loop(&listener, &shared));
        if let Err(e) = spawned {
            log::error(
                "cannot start accept thread",
                vec![("detail", Json::String(e.to_string()))],
            );
            return 1;
        }
    }
    while !signal::shutdown_requested() {
        std::thread::sleep(SIGNAL_POLL);
    }
    shutdown(&shared);
    0
}

/// Accepts connections until the process exits. During shutdown new
/// connections are still accepted, but are answered `503 SHUTTING_DOWN`
/// (`/health`: `shutting_down`) and closed.
fn accept_loop(listener: &TcpListener, shared: &Arc<Shared>) {
    loop {
        match listener.accept() {
            Ok((stream, _)) => spawn_connection(shared, stream),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => {
                log::warn(
                    "accept failed",
                    vec![("detail", Json::String(e.to_string()))],
                );
                std::thread::sleep(ACCEPT_BACKOFF);
            }
        }
    }
}

fn spawn_connection(shared: &Arc<Shared>, stream: TcpStream) {
    let shared = shared.clone();
    let spawned = std::thread::Builder::new()
        .name("http-conn".into())
        .stack_size(crate::protocol::WORKER_STACK_BYTES)
        .spawn(move || conn::handle(&shared, stream));
    if let Err(e) = spawned {
        log::error(
            "cannot start connection thread",
            vec![("detail", Json::String(e.to_string()))],
        );
    }
}

/// Graceful shutdown (concurrency.md §5).
fn shutdown(shared: &Shared) {
    shared.shutting_down.store(true, Ordering::SeqCst);
    let grace = Duration::from_millis(shared.serve.shutdown_grace_ms);
    log::info(
        "shutting down",
        vec![
            ("grace_ms", Json::uint(shared.serve.shutdown_grace_ms)),
            ("active_requests", Json::uint(shared.active() as u64)),
        ],
    );
    let start = Instant::now();
    while shared.active() > 0 && start.elapsed() < grace {
        std::thread::sleep(Duration::from_millis(5));
    }
    if shared.active() > 0 {
        log::warn(
            "grace period expired; cancelling queries",
            vec![("active_requests", Json::uint(shared.active() as u64))],
        );
        shared.registry.cancel_all();
        let start = Instant::now();
        while shared.active() > 0 && start.elapsed() < CANCEL_DRAIN {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    log::info("server stopped", vec![]);
}
