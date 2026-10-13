//! Interruption of a statement while it is parsed, bound and planned
//! (CR-6 §4: the timeout covers every stage of a query).
//!
//! Execution observes the deadline and the cancellation flag through its
//! `ExecContext`. The stages before it (parser, binder, optimizer, physical
//! planning) do not carry a context; instead the engine installs the
//! statement's [`Interrupt`] for the current thread while they run
//! ([`install`]), and the work in those stages that grows with the size of
//! the statement calls [`poll`].

use std::cell::{Cell, RefCell};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use crate::error::{Error, ErrorCode, Result};

/// When a statement must stop: its deadline and its cancellation flag.
#[derive(Debug, Clone, Default)]
pub struct Interrupt {
    pub deadline: Option<Instant>,
    pub cancel: Option<Arc<AtomicBool>>,
}

impl Interrupt {
    /// Fails with CANCELLED or TIMEOUT if the statement must stop.
    pub fn check(&self) -> Result<()> {
        if let Some(flag) = &self.cancel
            && flag.load(Ordering::Relaxed)
        {
            return Err(Error::new(ErrorCode::Cancelled, "query was cancelled"));
        }
        if let Some(d) = self.deadline
            && Instant::now() >= d
        {
            return Err(Error::new(ErrorCode::Timeout, "query exceeded its timeout"));
        }
        Ok(())
    }
}

/// Calls of [`poll`] between two looks at the clock.
const POLL_INTERVAL: u32 = 256;

thread_local! {
    static CURRENT: RefCell<Option<Interrupt>> = const { RefCell::new(None) };
    static COUNTDOWN: Cell<u32> = const { Cell::new(0) };
}

/// Makes `interrupt` the current thread's statement interrupt until the
/// returned guard is dropped (the previous one is restored then).
pub fn install(interrupt: Interrupt) -> Installed {
    let previous = CURRENT.with(|c| c.replace(Some(interrupt)));
    COUNTDOWN.with(|c| c.set(0));
    Installed { previous }
}

/// Restores the previous statement interrupt when dropped.
pub struct Installed {
    previous: Option<Interrupt>,
}

impl Drop for Installed {
    fn drop(&mut self) {
        let previous = self.previous.take();
        CURRENT.with(|c| *c.borrow_mut() = previous);
    }
}

/// Checks the current statement's interrupt now.
pub fn check() -> Result<()> {
    CURRENT.with(|c| match &*c.borrow() {
        Some(i) => i.check(),
        None => Ok(()),
    })
}

/// Cheap periodic check for loops and recursions: consults the clock on
/// every [`POLL_INTERVAL`]th call.
#[inline]
pub fn poll() -> Result<()> {
    let due = COUNTDOWN.with(|c| match c.get() {
        0 => {
            c.set(POLL_INTERVAL);
            true
        }
        n => {
            c.set(n - 1);
            false
        }
    });
    if due { check() } else { Ok(()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn installed_interrupt_is_polled_and_restored() {
        assert!(check().is_ok());
        {
            let _g = install(Interrupt {
                deadline: Some(Instant::now() - Duration::from_millis(1)),
                cancel: None,
            });
            assert_eq!(check().unwrap_err().code, ErrorCode::Timeout);
            let failed = (0..=POLL_INTERVAL).any(|_| poll().is_err());
            assert!(failed);
        }
        assert!(check().is_ok());
        let flag = Arc::new(AtomicBool::new(true));
        let _g = install(Interrupt {
            deadline: None,
            cancel: Some(flag),
        });
        assert_eq!(check().unwrap_err().code, ErrorCode::Cancelled);
    }
}
