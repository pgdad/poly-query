//! Stack-depth guard for the recursive processing of deep statements
//! (CR-6 §3: running out of stack, in any thread, must not terminate the
//! process).
//!
//! Every thread that parses, plans or executes statements is started with
//! [`spawn`], which gives it a large stack (only the pages actually used are
//! committed) and records where that stack ends. Recursive functions over
//! expression trees and plans call [`check`], which fails with
//! `RESOURCE_LIMIT` when less than [`RESERVE_BYTES`] of the stack remain,
//! instead of overflowing. The statement size limits (`sql::limits`) keep
//! every statement the engine accepts well within these stacks; the guard
//! is the safety net. Threads not started with [`spawn`] (e.g. unit test
//! threads) are not guarded.

use std::cell::Cell;
use std::io;
use std::thread::JoinHandle;

use crate::error::{Error, Result};

/// Stack size of threads that process requests (parse, bind, plan and
/// execute statements, row mode included).
pub const QUERY_STACK_BYTES: usize = 512 * 1024 * 1024;

/// Stack size of parallel worker threads (vectorized expression evaluation).
pub const WORKER_STACK_BYTES: usize = 256 * 1024 * 1024;

/// Stack kept free below the guard: room for the unguarded recursion
/// between two guarded calls and for unwinding the error.
pub const RESERVE_BYTES: usize = 8 * 1024 * 1024;

thread_local! {
    /// Lowest stack address guarded code may reach (0 = unguarded thread).
    static LIMIT: Cell<usize> = const { Cell::new(0) };
}

/// Starts a thread with a guarded stack of `size` bytes.
pub fn spawn<T: Send + 'static>(
    name: String,
    size: usize,
    f: impl FnOnce() -> T + Send + 'static,
) -> io::Result<JoinHandle<T>> {
    std::thread::Builder::new()
        .name(name)
        .stack_size(size)
        .spawn(move || {
            guard_current_thread(size);
            f()
        })
}

/// Runs `f` on a new guarded thread with a stack of `size` bytes, which may
/// borrow from the caller, and waits for its result. Used by the embedding
/// API so that statements run with the same stack guarantees as in the CLI,
/// whatever thread the host program calls from. A panic in `f` is
/// propagated as `Err` with the panic payload.
pub fn run_scoped<T: Send>(
    name: &str,
    size: usize,
    f: impl FnOnce() -> T + Send,
) -> io::Result<std::thread::Result<T>> {
    std::thread::scope(|scope| {
        let handle = std::thread::Builder::new()
            .name(name.to_string())
            .stack_size(size)
            .spawn_scoped(scope, move || {
                guard_current_thread(size);
                f()
            })?;
        Ok(handle.join())
    })
}

/// Guards the current thread, whose stack (growing downwards from about
/// here) is `size` bytes.
fn guard_current_thread(size: usize) {
    let limit = stack_pointer().saturating_sub(size) + RESERVE_BYTES.min(size / 2);
    LIMIT.with(|l| l.set(limit));
}

/// Fails with `RESOURCE_LIMIT` if the current thread's stack is nearly
/// exhausted.
#[inline]
pub fn check() -> Result<()> {
    if stack_pointer() < LIMIT.with(Cell::get) {
        return Err(Error::resource_limit(
            "expression nesting depth exceeds the engine's stack",
        ));
    }
    Ok(())
}

/// Approximate current stack pointer: the address of a local.
#[inline(always)]
fn stack_pointer() -> usize {
    let marker = 0u8;
    std::hint::black_box(&marker) as *const u8 as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    fn recurse(n: u64) -> Result<u64> {
        check()?;
        let pad = std::hint::black_box([n; 64]);
        Ok(recurse(n + 1)? + pad[0])
    }

    #[test]
    fn exhausted_stack_is_a_resource_limit() {
        let h = spawn("t".into(), 16 * 1024 * 1024, || recurse(0)).unwrap();
        let e = h.join().unwrap().unwrap_err();
        assert_eq!(e.code, crate::error::ErrorCode::ResourceLimit);
    }
}
