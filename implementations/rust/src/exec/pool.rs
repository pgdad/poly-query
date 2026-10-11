//! A process-wide pool of reusable worker threads for parallel execution.
//!
//! Starting an OS thread (with the large stack parallel workers need) costs
//! tens of microseconds, which adds up to a sizeable share of a
//! millisecond query that starts 16 workers several times. Finished workers
//! therefore park in the pool and take the next job. The pool never
//! queues: if no worker is idle, a new thread is started, so jobs that
//! block (e.g. gather workers waiting for their consumer) can never starve
//! other jobs or deadlock. At most [`MAX_IDLE`] idle threads are kept.

use std::any::Any;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};

use super::parallel::PARALLEL_STACK_BYTES;

/// Idle threads kept for reuse (more finish and exit).
const MAX_IDLE: usize = 256;

type Job = Box<dyn FnOnce() + Send + 'static>;

/// Senders of the idle workers' job channels.
static IDLE: Mutex<Vec<Sender<Job>>> = Mutex::new(Vec::new());

/// Runs `job` on an idle worker, or on a new thread if none is idle.
/// Returns the job back if no thread could be started.
fn dispatch(mut job: Job) -> Result<(), Job> {
    loop {
        let idle = IDLE.lock().unwrap_or_else(|e| e.into_inner()).pop();
        match idle {
            Some(worker) => match worker.send(job) {
                Ok(()) => return Ok(()),
                // The worker has exited; try the next one.
                Err(e) => job = e.0,
            },
            None => break,
        }
    }
    // The job is handed over through a shared slot, so that it can be
    // taken back if the thread cannot be started.
    let slot = Arc::new(Mutex::new(Some(job)));
    let theirs = slot.clone();
    let started = std::thread::Builder::new()
        .name("pq-worker".to_string())
        .stack_size(PARALLEL_STACK_BYTES)
        .spawn(move || {
            let job = theirs.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some(job) = job {
                let (tx, rx) = channel::<Job>();
                worker(job, tx, rx);
            }
        });
    match started {
        Ok(_) => Ok(()),
        Err(_) => match slot.lock().unwrap_or_else(|e| e.into_inner()).take() {
            Some(job) => Err(job),
            None => Ok(()),
        },
    }
}

fn worker(first: Job, tx: Sender<Job>, rx: Receiver<Job>) {
    let mut job = first;
    loop {
        // Jobs catch their own panics (see `spawn` / `scoped`).
        job();
        {
            let mut idle = IDLE.lock().unwrap_or_else(|e| e.into_inner());
            if idle.len() >= MAX_IDLE {
                return;
            }
            idle.push(tx.clone());
        }
        match rx.recv() {
            Ok(next) => job = next,
            Err(_) => return,
        }
    }
}

/// Handle of a job started with [`spawn`].
pub struct Task<T> {
    result: Receiver<std::thread::Result<T>>,
}

impl<T> Task<T> {
    /// Waits for the job; `Err` carries its panic payload.
    pub fn join(self) -> std::thread::Result<T> {
        self.result
            .recv()
            .unwrap_or_else(|_| Err(Box::new("worker thread terminated") as Box<dyn Any + Send>))
    }
}

/// Runs `f` on a pool thread.
pub fn spawn<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Task<T> {
    let (tx, rx) = channel();
    let job: Job = Box::new(move || {
        let _ = tx.send(catch_unwind(AssertUnwindSafe(f)));
    });
    if let Err(job) = dispatch(job) {
        job(); // no thread available: run here
    }
    Task { result: rx }
}

/// Drops `value` on a pool thread: freeing a large materialized input
/// (e.g. a million reference-counted strings) then does not delay the
/// query's response.
pub fn drop_in_background<T: Send + 'static>(value: T) {
    let _ = spawn(move || drop(value));
}

/// Runs the jobs in parallel (the first on the calling thread, the others
/// on pool threads) and returns their results in order. Returns only after
/// every job has finished; a panic in a job is then propagated.
pub fn scoped<'a, R: Send + 'a, F: FnOnce() -> R + Send + 'a>(jobs: Vec<F>) -> Vec<R> {
    let mut jobs = jobs.into_iter();
    let Some(first) = jobs.next() else {
        return Vec::new();
    };
    let mut pending = Vec::with_capacity(jobs.len());
    for f in jobs {
        let (tx, rx) = channel::<std::thread::Result<R>>();
        let job: Box<dyn FnOnce() + Send + 'a> = Box::new(move || {
            let _ = tx.send(catch_unwind(AssertUnwindSafe(f)));
        });
        // SAFETY: the job may borrow data living for 'a. This function
        // does not return (or unwind) before every dispatched job has
        // finished: each job sends exactly one message when done (its
        // panics are caught), and the loop below receives one message per
        // job before anything else can fail. A job that cannot be
        // dispatched is run (and finished) on this thread.
        let job: Job = unsafe { std::mem::transmute::<Box<dyn FnOnce() + Send + 'a>, Job>(job) };
        if let Err(job) = dispatch(job) {
            job();
        }
        pending.push(rx);
    }
    let first = catch_unwind(AssertUnwindSafe(first));
    let results: Vec<std::thread::Result<R>> = std::iter::once(first)
        .chain(pending.into_iter().map(|rx| {
            // A disconnected channel means the job was dropped without
            // running, which `dispatch` never does.
            rx.recv().unwrap_or_else(|_| {
                Err(Box::new("worker thread terminated") as Box<dyn Any + Send>)
            })
        }))
        .collect();
    results
        .into_iter()
        .map(|r| r.unwrap_or_else(|panic| resume_unwind(panic)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn scoped_jobs_borrow_and_return_in_order() {
        let data: Vec<usize> = (0..1000).collect();
        let jobs: Vec<_> = data
            .chunks(100)
            .map(|c| move || c.iter().sum::<usize>())
            .collect();
        let sums = scoped(jobs);
        assert_eq!(sums.len(), 10);
        assert_eq!(sums.iter().sum::<usize>(), 999 * 1000 / 2);
        assert_eq!(sums[0], (0..100).sum());
    }

    #[test]
    fn threads_are_reused_and_panics_propagate() {
        static RUNS: AtomicUsize = AtomicUsize::new(0);
        for _ in 0..20 {
            let tasks: Vec<_> = (0..4)
                .map(|i| {
                    spawn(move || {
                        RUNS.fetch_add(1, Ordering::Relaxed);
                        i * 2
                    })
                })
                .collect();
            let got: Vec<usize> = tasks.into_iter().map(|t| t.join().unwrap()).collect();
            assert_eq!(got, vec![0, 2, 4, 6]);
        }
        assert!(RUNS.load(Ordering::Relaxed) >= 80);
        assert!(spawn(|| panic!("boom")).join().is_err());
        let r = catch_unwind(|| scoped(vec![|| 1, || panic!("inner")]));
        assert!(r.is_err());
        // The pool still works after panics.
        assert_eq!(spawn(|| 7).join().unwrap(), 7);
    }
}
