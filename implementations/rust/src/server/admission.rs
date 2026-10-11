//! Admission control (concurrency.md §2): at most `workers` queries execute
//! at once, up to `queue_depth` more wait in FIFO order, anything beyond is
//! rejected immediately with `OVERLOADED`.

use std::collections::VecDeque;
use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use crate::error::{Error, ErrorCode, Result};

/// How often a waiting query re-checks its stop condition (cancellation,
/// timeout) while queued.
const WAIT_SLICE: Duration = Duration::from_millis(5);

#[derive(Debug, Default)]
struct State {
    running: usize,
    /// Tickets of waiting queries, oldest first.
    queue: VecDeque<u64>,
    next_ticket: u64,
}

#[derive(Debug)]
pub struct Admission {
    workers: usize,
    queue_depth: usize,
    state: Mutex<State>,
    changed: Condvar,
}

/// A query's place in admission: either already holding a worker slot or
/// waiting in the queue.
#[derive(Debug, Clone, Copy)]
#[must_use]
pub enum Ticket {
    Running,
    Queued(u64),
}

/// A worker slot; released on drop.
#[derive(Debug)]
pub struct Permit<'a> {
    admission: &'a Admission,
}

impl Drop for Permit<'_> {
    fn drop(&mut self) {
        let mut st = self.admission.lock();
        st.running -= 1;
        drop(st);
        self.admission.changed.notify_all();
    }
}

impl Admission {
    pub fn new(workers: usize, queue_depth: usize) -> Self {
        Admission {
            workers: workers.max(1),
            queue_depth,
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Admits a query: takes a free worker slot if nobody is waiting, else a
    /// queue position, else fails with `OVERLOADED`.
    pub fn enter(&self) -> Result<Ticket> {
        let mut st = self.lock();
        if st.running < self.workers && st.queue.is_empty() {
            st.running += 1;
            return Ok(Ticket::Running);
        }
        if st.queue.len() < self.queue_depth {
            let t = st.next_ticket;
            st.next_ticket += 1;
            st.queue.push_back(t);
            return Ok(Ticket::Queued(t));
        }
        Err(Error::new(
            ErrorCode::Overloaded,
            format!(
                "server overloaded: {} queries running and {} queued",
                st.running,
                st.queue.len()
            ),
        ))
    }

    /// Waits until the ticket holds a worker slot. `stop` is polled while
    /// waiting; if it returns an error the ticket leaves the queue and that
    /// error is returned.
    pub fn wait(&self, ticket: Ticket, stop: impl Fn() -> Result<()>) -> Result<Permit<'_>> {
        let Ticket::Queued(id) = ticket else {
            return Ok(Permit { admission: self });
        };
        let mut st = self.lock();
        loop {
            if st.queue.front() == Some(&id) && st.running < self.workers {
                st.queue.pop_front();
                st.running += 1;
                drop(st);
                // The next waiter may be admissible too.
                self.changed.notify_all();
                return Ok(Permit { admission: self });
            }
            if let Err(e) = stop() {
                st.queue.retain(|&t| t != id);
                drop(st);
                self.changed.notify_all();
                return Err(e);
            }
            st = self
                .changed
                .wait_timeout(st, WAIT_SLICE)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }

    /// Gives up a ticket that will never be waited on.
    pub fn abandon(&self, ticket: Ticket) {
        let mut st = self.lock();
        match ticket {
            Ticket::Running => st.running -= 1,
            Ticket::Queued(id) => st.queue.retain(|&t| t != id),
        }
        drop(st);
        self.changed.notify_all();
    }

    /// Queries currently executing.
    pub fn running(&self) -> usize {
        self.lock().running
    }

    /// Queries currently waiting for a worker.
    pub fn queued(&self) -> usize {
        self.lock().queue.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn limits_and_fifo() {
        let a = Admission::new(1, 1);
        let t1 = a.enter().unwrap();
        let p1 = a.wait(t1, || Ok(())).unwrap();
        let t2 = a.enter().unwrap();
        assert!(matches!(t2, Ticket::Queued(_)));
        assert_eq!(a.enter().unwrap_err().code, ErrorCode::Overloaded);
        assert_eq!((a.running(), a.queued()), (1, 1));
        drop(p1);
        let p2 = a.wait(t2, || Ok(())).unwrap();
        assert_eq!((a.running(), a.queued()), (1, 0));
        drop(p2);
        assert_eq!(a.running(), 0);
    }

    #[test]
    fn stop_leaves_queue() {
        let a = Arc::new(Admission::new(1, 4));
        let p = a.wait(a.enter().unwrap(), || Ok(())).unwrap();
        let t = a.enter().unwrap();
        let err = a
            .wait(t, || Err(Error::new(ErrorCode::Timeout, "t")))
            .unwrap_err();
        assert_eq!(err.code, ErrorCode::Timeout);
        assert_eq!(a.queued(), 0);
        drop(p);
    }
}
