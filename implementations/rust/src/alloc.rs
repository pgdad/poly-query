//! The process's global allocator: the system allocator (glibc `malloc`)
//! with a `realloc` that keeps reallocated blocks in the calling thread's
//! malloc arena.
//!
//! Parallel execution reuses long-lived worker threads (`exec::pool`).
//! glibc's per-thread cache (tcache) keeps small blocks a thread frees even
//! if they belong to another thread's arena (job closures and channel nodes
//! are allocated by the dispatching thread and freed by the worker). When a
//! worker reuses such a block for a vector, glibc's `realloc` grows the
//! vector *inside the foreign arena*, under that arena's lock, so over time
//! the workers' vectors migrate into the dispatcher's arena and the threads
//! contend on one lock (measured: 2× slower parallel join probes).
//! Reallocating as allocate-copy-free places the grown block in the
//! caller's own arena. Huge blocks (which glibc `mmap`s, and grows with
//! `mremap` without any arena lock) still use the system `realloc`.

use std::alloc::{GlobalAlloc, Layout, System};

/// Blocks from this size on are reallocated by the system allocator (they
/// are above glibc's largest dynamic `mmap` threshold).
const SYSTEM_REALLOC_BYTES: usize = 32 << 20;

/// Global allocator (registered by the `polyquery` binary).
pub struct ArenaLocalAlloc;

// SAFETY: every method forwards to `System` with layouts valid for it;
// `realloc` allocates a block of the new layout, copies the overlapping
// prefix and frees the old block only if the allocation succeeded (on
// failure the old block stays valid, as `GlobalAlloc::realloc` requires).
unsafe impl GlobalAlloc for ArenaLocalAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if layout.size() >= SYSTEM_REALLOC_BYTES {
            return unsafe { System.realloc(ptr, layout, new_size) };
        }
        unsafe {
            // The caller guarantees that `new_size`, rounded up to the
            // alignment, does not overflow `isize`.
            let new_layout = Layout::from_size_align_unchecked(new_size, layout.align());
            let new = System.alloc(new_layout);
            if !new.is_null() {
                std::ptr::copy_nonoverlapping(ptr, new, layout.size().min(new_size));
                System.dealloc(ptr, layout);
            }
            new
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn realloc_keeps_contents() {
        let a = ArenaLocalAlloc;
        unsafe {
            let l = Layout::from_size_align(16, 8).unwrap();
            let p = a.alloc(l);
            for i in 0..16 {
                *p.add(i) = i as u8;
            }
            let q = a.realloc(p, l, 4096);
            assert!((0..16).all(|i| *q.add(i) == i as u8));
            let r = a.realloc(q, Layout::from_size_align(4096, 8).unwrap(), 8);
            assert!((0..8).all(|i| *r.add(i) == i as u8));
            a.dealloc(r, Layout::from_size_align(8, 8).unwrap());
        }
    }
}
