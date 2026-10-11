//! SIGTERM/SIGINT handling for graceful shutdown. The C `signal` function is
//! declared directly against the system libc (no crates); the handler only
//! stores to an atomic flag, which is async-signal-safe.

use std::os::raw::c_int;
use std::sync::atomic::{AtomicBool, Ordering};

const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;

static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);

unsafe extern "C" {
    /// `sighandler_t signal(int signum, sighandler_t handler);`
    fn signal(signum: c_int, handler: extern "C" fn(c_int)) -> usize;
}

extern "C" fn on_signal(_signum: c_int) {
    SHUTDOWN_REQUESTED.store(true, Ordering::SeqCst);
}

/// Installs the handlers for SIGTERM and SIGINT.
pub fn install() {
    // SAFETY: `on_signal` is a valid `extern "C"` handler that only performs
    // an atomic store; `signal` is the standard libc function.
    unsafe {
        signal(SIGTERM, on_signal);
        signal(SIGINT, on_signal);
    }
}

/// Whether a termination signal has been received.
pub fn shutdown_requested() -> bool {
    SHUTDOWN_REQUESTED.load(Ordering::SeqCst)
}
