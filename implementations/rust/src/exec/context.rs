//! Per-query execution context: timeout, cancellation, memory budget, join
//! size limit, and the state of subquery evaluation (correlation parameters
//! and result caches).

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use super::subquery::SubqueryResult;
use crate::error::{Error, ErrorCode, Result};
use crate::planner::{PhysicalOptions, PhysicalPlan};
use crate::types::Value;

/// Maximum number of memoized subquery results per query.
const MAX_CACHED_SUBQUERY_RESULTS: usize = 100_000;

/// Cache key of a subquery execution: (subquery id, parameter values).
type SubqueryKey = (usize, Vec<Value>);

#[derive(Debug)]
pub struct ExecContext {
    deadline: Option<Instant>,
    cancel: Option<Arc<AtomicBool>>,
    memory_limit: usize,
    memory_used: Cell<usize>,
    max_join_rows: u64,
    join_rows: Cell<u64>,
    /// Whether test-only functions may run.
    pub test_functions: bool,
    /// Options for lowering subquery plans.
    pub physical: PhysicalOptions,
    /// Correlation parameters of the subquery executions in progress
    /// (innermost last).
    params: RefCell<Vec<Rc<[Value]>>>,
    /// Lowered subquery plans by subquery id.
    plans: RefCell<HashMap<usize, Rc<PhysicalPlan>>>,
    /// Subquery results by (subquery id, parameter values).
    results: RefCell<HashMap<SubqueryKey, Rc<SubqueryResult>>>,
}

impl Default for ExecContext {
    fn default() -> Self {
        ExecContext::new(None, usize::MAX, false)
    }
}

impl ExecContext {
    pub fn new(timeout: Option<Duration>, memory_limit: usize, test_functions: bool) -> Self {
        ExecContext {
            deadline: timeout.map(|t| Instant::now() + t),
            cancel: None,
            memory_limit,
            memory_used: Cell::new(0),
            max_join_rows: u64::MAX,
            join_rows: Cell::new(0),
            test_functions,
            physical: PhysicalOptions::default(),
            params: RefCell::new(Vec::new()),
            plans: RefCell::new(HashMap::new()),
            results: RefCell::new(HashMap::new()),
        }
    }

    pub fn with_cancel_flag(mut self, flag: Arc<AtomicBool>) -> Self {
        self.cancel = Some(flag);
        self
    }

    pub fn with_max_join_rows(mut self, n: u64) -> Self {
        self.max_join_rows = n;
        self
    }

    pub fn with_physical_options(mut self, opts: PhysicalOptions) -> Self {
        self.physical = opts;
        self
    }

    /// Fails with TIMEOUT or CANCELLED if the query must stop.
    pub fn check_interrupt(&self) -> Result<()> {
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
        self.memory_used
            .set(self.memory_used.get().saturating_sub(bytes));
    }

    /// Counts rows produced by join operators against `--max-join-rows`.
    pub fn count_join_rows(&self, n: u64) -> Result<()> {
        let total = self.join_rows.get().saturating_add(n);
        self.join_rows.set(total);
        if total > self.max_join_rows {
            return Err(Error::resource_limit(format!(
                "join produced more than {} rows (--max-join-rows)",
                self.max_join_rows
            )));
        }
        Ok(())
    }

    /// Value of correlation parameter `index` of the innermost subquery.
    pub fn param(&self, index: usize) -> Result<Value> {
        self.params
            .borrow()
            .last()
            .and_then(|p| p.get(index).cloned())
            .ok_or_else(|| Error::internal(format!("unbound correlation parameter {index}")))
    }

    /// Runs `f` with `params` as the innermost correlation parameters.
    pub fn with_params<T>(&self, params: Rc<[Value]>, f: impl FnOnce() -> Result<T>) -> Result<T> {
        self.params.borrow_mut().push(params);
        let r = f();
        self.params.borrow_mut().pop();
        r
    }

    pub fn cached_plan(&self, id: usize) -> Option<Rc<PhysicalPlan>> {
        self.plans.borrow().get(&id).cloned()
    }

    pub fn cache_plan(&self, id: usize, plan: Rc<PhysicalPlan>) {
        self.plans.borrow_mut().insert(id, plan);
    }

    pub fn cached_result(&self, key: &SubqueryKey) -> Option<Rc<SubqueryResult>> {
        self.results.borrow().get(key).cloned()
    }

    pub fn cache_result(&self, key: SubqueryKey, result: Rc<SubqueryResult>) {
        let mut results = self.results.borrow_mut();
        if results.len() < MAX_CACHED_SUBQUERY_RESULTS {
            results.insert(key, result);
        }
    }
}
