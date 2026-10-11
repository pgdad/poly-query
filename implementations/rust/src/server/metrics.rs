//! Server metrics in the Prometheus text exposition format 0.0.4
//! (protocol.md §7.3).

use std::fmt::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use crate::error::ErrorCode;

pub const CONTENT_TYPE: &str = "text/plain; version=0.0.4; charset=utf-8";

#[derive(Debug)]
pub struct Metrics {
    started: Instant,
    queries_ok: AtomicU64,
    queries_error: AtomicU64,
    rejected: AtomicU64,
    cancelled: AtomicU64,
    timeouts: AtomicU64,
    duration_us_sum: AtomicU64,
    duration_count: AtomicU64,
    http_requests: AtomicU64,
}

/// Gauges sampled when metrics are rendered.
#[derive(Debug, Clone, Copy)]
pub struct Gauges {
    pub in_flight: usize,
    pub queued: usize,
    pub tables: usize,
}

impl Default for Metrics {
    fn default() -> Self {
        Metrics {
            started: Instant::now(),
            queries_ok: AtomicU64::new(0),
            queries_error: AtomicU64::new(0),
            rejected: AtomicU64::new(0),
            cancelled: AtomicU64::new(0),
            timeouts: AtomicU64::new(0),
            duration_us_sum: AtomicU64::new(0),
            duration_count: AtomicU64::new(0),
            http_requests: AtomicU64::new(0),
        }
    }
}

fn inc(c: &AtomicU64) {
    c.fetch_add(1, Ordering::Relaxed);
}

fn get(c: &AtomicU64) -> u64 {
    c.load(Ordering::Relaxed)
}

impl Metrics {
    /// Records a finished query (`error` is its error code, if it failed).
    pub fn query_finished(&self, error: Option<ErrorCode>, duration: Duration) {
        match error {
            None => inc(&self.queries_ok),
            Some(code) => {
                inc(&self.queries_error);
                match code {
                    ErrorCode::Cancelled => inc(&self.cancelled),
                    ErrorCode::Timeout => inc(&self.timeouts),
                    ErrorCode::Overloaded => inc(&self.rejected),
                    _ => {}
                }
            }
        }
        if error != Some(ErrorCode::Overloaded) {
            self.duration_us_sum
                .fetch_add(duration.as_micros() as u64, Ordering::Relaxed);
            inc(&self.duration_count);
        }
    }

    pub fn http_request(&self) {
        inc(&self.http_requests);
    }

    pub fn render(&self, g: Gauges) -> String {
        let mut out = String::with_capacity(2048);
        let mut family = |name: &str, kind: &str, help: &str, samples: &[(&str, String)]| {
            let _ = writeln!(out, "# HELP {name} {help}");
            let _ = writeln!(out, "# TYPE {name} {kind}");
            for (suffix, value) in samples {
                let _ = writeln!(out, "{name}{suffix} {value}");
            }
        };
        family(
            "polyquery_queries_total",
            "counter",
            "Finished queries by outcome.",
            &[
                ("{status=\"ok\"}", get(&self.queries_ok).to_string()),
                ("{status=\"error\"}", get(&self.queries_error).to_string()),
            ],
        );
        family(
            "polyquery_queries_in_flight",
            "gauge",
            "Queries currently executing.",
            &[("", g.in_flight.to_string())],
        );
        family(
            "polyquery_queries_queued",
            "gauge",
            "Queries waiting for a worker.",
            &[("", g.queued.to_string())],
        );
        family(
            "polyquery_queries_rejected_total",
            "counter",
            "Queries rejected with OVERLOADED.",
            &[("", get(&self.rejected).to_string())],
        );
        family(
            "polyquery_queries_cancelled_total",
            "counter",
            "Queries that ended CANCELLED.",
            &[("", get(&self.cancelled).to_string())],
        );
        family(
            "polyquery_queries_timeout_total",
            "counter",
            "Queries that ended with TIMEOUT.",
            &[("", get(&self.timeouts).to_string())],
        );
        family(
            "polyquery_query_duration_seconds",
            "summary",
            "Query duration from arrival to completion.",
            &[
                (
                    "_sum",
                    format!("{:.6}", get(&self.duration_us_sum) as f64 / 1e6),
                ),
                ("_count", get(&self.duration_count).to_string()),
            ],
        );
        family(
            "polyquery_tables",
            "gauge",
            "Tables in the catalog.",
            &[("", g.tables.to_string())],
        );
        family(
            "polyquery_uptime_seconds",
            "gauge",
            "Seconds since the server started.",
            &[("", format!("{:.3}", self.started.elapsed().as_secs_f64()))],
        );
        family(
            "polyquery_http_requests_total",
            "counter",
            "HTTP requests received.",
            &[("", get(&self.http_requests).to_string())],
        );
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_counters() {
        let m = Metrics::default();
        m.query_finished(None, Duration::from_millis(5));
        m.query_finished(Some(ErrorCode::Timeout), Duration::from_millis(5));
        m.query_finished(Some(ErrorCode::Overloaded), Duration::ZERO);
        let text = m.render(Gauges {
            in_flight: 2,
            queued: 1,
            tables: 3,
        });
        assert!(text.contains("polyquery_queries_total{status=\"ok\"} 1\n"));
        assert!(text.contains("polyquery_queries_total{status=\"error\"} 2\n"));
        assert!(text.contains("polyquery_queries_timeout_total 1\n"));
        assert!(text.contains("polyquery_queries_rejected_total 1\n"));
        assert!(text.contains("polyquery_query_duration_seconds_count 2\n"));
        assert!(text.contains("polyquery_queries_in_flight 2\n"));
        assert!(text.contains("polyquery_tables 3\n"));
    }
}
