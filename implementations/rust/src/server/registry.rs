//! Registry of queued and running queries by `query_id`, used for listing
//! (`GET /v1/queries`), cancellation and duplicate-id detection.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Instant;

use crate::error::{Error, ErrorCode, Result};

/// One registered query.
#[derive(Debug)]
pub struct QueryHandle {
    pub id: String,
    pub started: Instant,
    /// Set to request cancellation; observed by the executing query.
    pub cancel: Arc<AtomicBool>,
    running: AtomicBool,
}

impl QueryHandle {
    pub fn set_running(&self) {
        self.running.store(true, Ordering::Relaxed);
    }

    pub fn state(&self) -> &'static str {
        if self.running.load(Ordering::Relaxed) {
            "running"
        } else {
            "queued"
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }

    pub fn request_cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
    }
}

#[derive(Debug, Default)]
pub struct Registry {
    queries: Mutex<HashMap<String, Arc<QueryHandle>>>,
    counter: AtomicU64,
}

impl Registry {
    fn lock(&self) -> MutexGuard<'_, HashMap<String, Arc<QueryHandle>>> {
        self.queries.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Registers a query under the client's id or a generated one. An id in
    /// use by a queued or running query is `ALREADY_EXISTS`.
    pub fn register(&self, id: Option<&str>) -> Result<Arc<QueryHandle>> {
        let mut map = self.lock();
        let id = match id {
            Some(id) => {
                if map.contains_key(id) {
                    return Err(Error::new(
                        ErrorCode::AlreadyExists,
                        format!("query_id '{id}' is already in use"),
                    ));
                }
                id.to_string()
            }
            None => loop {
                let n = self.counter.fetch_add(1, Ordering::Relaxed) + 1;
                let candidate = format!("q-{n}");
                if !map.contains_key(&candidate) {
                    break candidate;
                }
            },
        };
        let handle = Arc::new(QueryHandle {
            id: id.clone(),
            started: Instant::now(),
            cancel: Arc::new(AtomicBool::new(false)),
            running: AtomicBool::new(false),
        });
        map.insert(id, handle.clone());
        Ok(handle)
    }

    /// Removes a finished query (only if `handle` is still the registered one).
    pub fn unregister(&self, handle: &Arc<QueryHandle>) {
        let mut map = self.lock();
        if map.get(&handle.id).is_some_and(|h| Arc::ptr_eq(h, handle)) {
            map.remove(&handle.id);
        }
    }

    /// Requests cancellation; false if no such query is queued or running.
    pub fn cancel(&self, id: &str) -> bool {
        match self.lock().get(id) {
            Some(h) => {
                h.request_cancel();
                true
            }
            None => false,
        }
    }

    pub fn cancel_all(&self) {
        for h in self.lock().values() {
            h.request_cancel();
        }
    }

    /// Registered queries, oldest first.
    pub fn list(&self) -> Vec<Arc<QueryHandle>> {
        let mut all: Vec<_> = self.lock().values().cloned().collect();
        all.sort_by_key(|h| h.started);
        all
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_cancel_unregister() {
        let r = Registry::default();
        let a = r.register(Some("a")).unwrap();
        assert_eq!(
            r.register(Some("a")).unwrap_err().code,
            ErrorCode::AlreadyExists
        );
        let b = r.register(None).unwrap();
        assert_ne!(b.id, "a");
        assert!(r.cancel("a"));
        assert!(a.is_cancelled() && !b.is_cancelled());
        r.unregister(&a);
        assert!(!r.cancel("a"));
        assert_eq!(r.list().len(), 1);
    }
}
