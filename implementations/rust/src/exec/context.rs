//! Per-query execution context: timeout, cancellation, memory budget, join
//! size limit, and the state of subquery evaluation (correlation parameters
//! and result caches).

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use super::operators::Row;
use super::subquery::SubqueryResult;
use crate::error::{Error, ErrorCode, Result};
use crate::planner::{PhysicalOptions, PhysicalPlan};
use crate::types::Value;

/// Maximum number of memoized subquery results per query.
const MAX_CACHED_SUBQUERY_RESULTS: usize = 100_000;

/// Hash table of a ParamLookup input: normalized key values → rows.
pub type LookupTable = HashMap<Vec<Value>, Vec<Row>>;

/// Cache key of a subquery execution: (subquery id, parameter values).
type SubqueryKey = (usize, Vec<Value>);

/// Execution model options (query options `mode` and `threads`).
#[derive(Debug, Clone, Copy)]
pub struct ExecOptions {
    /// Batch-at-a-time execution (`mode: "vectorized"`) instead of the
    /// row-at-a-time baseline.
    pub vectorized: bool,
    /// Worker threads for parallel scans/aggregation (vectorized mode).
    pub threads: usize,
    /// Rows per morsel of parallel scans.
    pub morsel_rows: usize,
    /// Native kernels to use (`native: true` with a loaded library).
    pub native: Option<&'static crate::native::Kernels>,
}

impl Default for ExecOptions {
    fn default() -> Self {
        ExecOptions {
            vectorized: false,
            threads: 1,
            morsel_rows: super::parallel::default_morsel_rows(),
            native: None,
        }
    }
}

/// Budgets shared by all threads executing one query.
#[derive(Debug, Default)]
struct Shared {
    memory_used: AtomicUsize,
    join_rows: AtomicU64,
}

#[derive(Debug)]
pub struct ExecContext {
    deadline: Option<Instant>,
    cancel: Option<Arc<AtomicBool>>,
    /// Set when the consumer of a parallel worker's output no longer needs
    /// it (the worker then stops like a cancelled query).
    stop: Option<Arc<AtomicBool>>,
    memory_limit: usize,
    max_join_rows: u64,
    shared: Arc<Shared>,
    /// Whether test-only functions may run.
    pub test_functions: bool,
    /// Options for lowering subquery plans.
    pub physical: PhysicalOptions,
    /// Execution model.
    pub exec: ExecOptions,
    /// Correlation parameters of the subquery executions in progress
    /// (innermost last).
    params: RefCell<Vec<Arc<[Value]>>>,
    /// Lowered subquery plans by subquery id.
    plans: RefCell<HashMap<usize, Rc<PhysicalPlan>>>,
    /// Subquery results by (subquery id, parameter values).
    results: RefCell<HashMap<SubqueryKey, Rc<SubqueryResult>>>,
    /// ParamLookup hash tables by node id.
    lookups: RefCell<HashMap<usize, Rc<LookupTable>>>,
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
            stop: None,
            memory_limit,
            max_join_rows: u64::MAX,
            shared: Arc::new(Shared::default()),
            test_functions,
            physical: PhysicalOptions::default(),
            exec: ExecOptions::default(),
            params: RefCell::new(Vec::new()),
            plans: RefCell::new(HashMap::new()),
            results: RefCell::new(HashMap::new()),
            lookups: RefCell::new(HashMap::new()),
        }
    }

    /// Replaces the deadline (None = no timeout).
    pub fn with_deadline(mut self, deadline: Option<Instant>) -> Self {
        self.deadline = deadline;
        self
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

    pub fn with_exec_options(mut self, opts: ExecOptions) -> Self {
        self.exec = opts;
        self
    }

    /// Everything a worker thread needs to build its own context for the
    /// same query (deadline, cancellation, shared budgets, options and the
    /// current correlation parameters).
    pub fn seed(&self) -> ContextSeed {
        ContextSeed {
            deadline: self.deadline,
            cancel: self.cancel.clone(),
            memory_limit: self.memory_limit,
            max_join_rows: self.max_join_rows,
            shared: self.shared.clone(),
            test_functions: self.test_functions,
            physical: self.physical,
            exec: self.exec,
            params: self.params.borrow().clone(),
        }
    }

    /// True while executing (correlated) subquery code.
    pub fn in_subquery(&self) -> bool {
        !self.params.borrow().is_empty()
    }

    /// Fails with TIMEOUT or CANCELLED if the query must stop.
    pub fn check_interrupt(&self) -> Result<()> {
        if let Some(flag) = &self.cancel
            && flag.load(Ordering::Relaxed)
        {
            return Err(Error::new(ErrorCode::Cancelled, "query was cancelled"));
        }
        if let Some(flag) = &self.stop
            && flag.load(Ordering::Relaxed)
        {
            return Err(Error::new(
                ErrorCode::Cancelled,
                "parallel work is no longer needed",
            ));
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
        let used = self
            .shared
            .memory_used
            .fetch_add(bytes, Ordering::Relaxed)
            .saturating_add(bytes);
        if used > self.memory_limit {
            return Err(Error::resource_limit(format!(
                "query exceeded its memory budget of {} MiB",
                self.memory_limit / (1024 * 1024)
            )));
        }
        Ok(())
    }

    pub fn release(&self, bytes: usize) {
        let _ = self
            .shared
            .memory_used
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |u| {
                Some(u.saturating_sub(bytes))
            });
    }

    /// Counts rows produced by join operators against `--max-join-rows`.
    pub fn count_join_rows(&self, n: u64) -> Result<()> {
        let total = self
            .shared
            .join_rows
            .fetch_add(n, Ordering::Relaxed)
            .saturating_add(n);
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
    pub fn with_params<T>(&self, params: Arc<[Value]>, f: impl FnOnce() -> Result<T>) -> Result<T> {
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

    pub fn cached_lookup(&self, id: usize) -> Option<Rc<LookupTable>> {
        self.lookups.borrow().get(&id).cloned()
    }

    pub fn cache_lookup(&self, id: usize, table: Rc<LookupTable>) {
        self.lookups.borrow_mut().insert(id, table);
    }
}

/// Sendable description of a query's execution context (see
/// [`ExecContext::seed`]); worker threads build their own context from it.
/// Subquery result caches are per context.
#[derive(Debug, Clone)]
pub struct ContextSeed {
    deadline: Option<Instant>,
    cancel: Option<Arc<AtomicBool>>,
    memory_limit: usize,
    max_join_rows: u64,
    shared: Arc<Shared>,
    test_functions: bool,
    physical: PhysicalOptions,
    exec: ExecOptions,
    params: Vec<Arc<[Value]>>,
}

impl ContextSeed {
    pub fn context(&self) -> ExecContext {
        ExecContext {
            deadline: self.deadline,
            cancel: self.cancel.clone(),
            stop: None,
            memory_limit: self.memory_limit,
            max_join_rows: self.max_join_rows,
            shared: self.shared.clone(),
            test_functions: self.test_functions,
            physical: self.physical,
            exec: self.exec,
            params: RefCell::new(self.params.clone()),
            plans: RefCell::new(HashMap::new()),
            results: RefCell::new(HashMap::new()),
            lookups: RefCell::new(HashMap::new()),
        }
    }

    /// A worker context that also stops when `stop` is set.
    pub fn worker_context(&self, stop: Arc<AtomicBool>) -> ExecContext {
        let mut ctx = self.context();
        ctx.stop = Some(stop);
        ctx
    }
}
