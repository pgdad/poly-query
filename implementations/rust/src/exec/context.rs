//! Per-query execution context: timeout, cancellation and memory budget.

use std::cell::Cell;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use crate::error::{Error, ErrorCode, Result};

#[derive(Debug)]
pub struct ExecContext {
    deadline: Option<Instant>,
    cancel: Option<Arc<AtomicBool>>,
    memory_limit: usize,
    memory_used: Cell<usize>,
    /// Whether test-only functions may run.
    pub test_functions: bool,
}

impl Default for ExecContext {
    fn default() -> Self {
        ExecContext {
            deadline: None,
            cancel: None,
            memory_limit: usize::MAX,
            memory_used: Cell::new(0),
            test_functions: false,
        }
    }
}

impl ExecContext {
    pub fn new(timeout: Option<Duration>, memory_limit: usize, test_functions: bool) -> Self {
        ExecContext {
            deadline: timeout.map(|t| Instant::now() + t),
            cancel: None,
            memory_limit,
            memory_used: Cell::new(0),
            test_functions,
        }
    }

    pub fn with_cancel_flag(mut self, flag: Arc<AtomicBool>) -> Self {
        self.cancel = Some(flag);
        self
    }

    /// Fails with TIMEOUT or CANCELLED if the query must stop.
    pub fn check_interrupt(&self) -> Result<()> {
        if let Some(flag) = &self.cancel {
            if flag.load(Ordering::Relaxed) {
                return Err(Error::new(ErrorCode::Cancelled, "query was cancelled"));
            }
        }
        if let Some(d) = self.deadline {
            if Instant::now() >= d {
                return Err(Error::new(ErrorCode::Timeout, "query exceeded its timeout"));
            }
        }
        Ok(())
    }

    /// Sleeps for `d`, waking at least every 5 ms to observe interruption.
    pub fn sleep(&self, d: Duration) -> Result<()> {
        let end = Instant::now() + d;
        loop {
            self.check_interrupt()?;
            let now = Instant::now();
            if now >= end {
                return Ok(());
            }
            std::thread::sleep((end - now).min(Duration::from_millis(5)));
        }
    }

    /// Accounts `bytes` of materialized state against the memory budget.
    pub fn reserve(&self, bytes: usize) -> Result<()> {
        let used = self.memory_used.get().saturating_add(bytes);
        self.memory_used.set(used);
        if used > self.memory_limit {
            return Err(Error::resource_limit(format!(
                "query exceeded its memory budget of {} MiB",
                self.memory_limit / (1024 * 1024)
            )));
        }
        Ok(())
    }

    pub fn release(&self, bytes: usize) {
        self.memory_used.set(self.memory_used.get().saturating_sub(bytes));
    }
}
