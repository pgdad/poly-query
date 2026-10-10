//! Read-only memory mapping of a file (`storage.mmap`), declared directly
//! against the system C library since only `std` may be used.

use std::fs::File;
use std::io;

#[cfg(unix)]
mod sys {
    use std::ffi::c_void;

    pub const PROT_READ: i32 = 1;
    pub const MAP_PRIVATE: i32 = 2;

    unsafe extern "C" {
        pub fn mmap(
            addr: *mut c_void,
            len: usize,
            prot: i32,
            flags: i32,
            fd: i32,
            offset: i64,
        ) -> *mut c_void;
        pub fn munmap(addr: *mut c_void, len: usize) -> i32;
    }
}

/// A read-only private mapping of a whole file.
#[derive(Debug)]
pub struct Mmap {
    ptr: *const u8,
    len: usize,
}

// SAFETY: the mapping is read-only and never mutated through this handle;
// PQCF files are immutable while open (pqcf-v1.md §4).
unsafe impl Send for Mmap {}
unsafe impl Sync for Mmap {}

impl Mmap {
    /// Maps `len` bytes of `file` (`len` must be > 0 and ≤ the file size).
    #[cfg(unix)]
    pub fn map(file: &File, len: usize) -> io::Result<Mmap> {
        use std::os::fd::AsRawFd;
        if len == 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty mapping"));
        }
        // SAFETY: a fresh mapping of a valid descriptor; the result is checked.
        let ptr = unsafe {
            sys::mmap(
                std::ptr::null_mut(),
                len,
                sys::PROT_READ,
                sys::MAP_PRIVATE,
                file.as_raw_fd(),
                0,
            )
        };
        if ptr as isize == -1 || ptr.is_null() {
            return Err(io::Error::last_os_error());
        }
        Ok(Mmap {
            ptr: ptr as *const u8,
            len,
        })
    }

    #[cfg(not(unix))]
    pub fn map(_file: &File, _len: usize) -> io::Result<Mmap> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "memory mapping is not supported on this platform",
        ))
    }

    pub fn as_slice(&self) -> &[u8] {
        // SAFETY: ptr/len describe a live read-only mapping owned by self.
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }
}

impl Drop for Mmap {
    fn drop(&mut self) {
        #[cfg(unix)]
        // SAFETY: unmapping the region created in `map` exactly once.
        unsafe {
            sys::munmap(self.ptr as *mut std::ffi::c_void, self.len);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn maps_file_contents() {
        let path = std::env::temp_dir().join(format!("pq-mmap-test-{}", std::process::id()));
        File::create(&path)
            .unwrap()
            .write_all(b"hello mmap")
            .unwrap();
        let f = File::open(&path).unwrap();
        let m = Mmap::map(&f, 10).unwrap();
        assert_eq!(m.as_slice(), b"hello mmap");
        drop(m);
        std::fs::remove_file(&path).unwrap();
    }
}
