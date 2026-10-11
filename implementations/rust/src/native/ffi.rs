//! Raw FFI: dynamic loading (`dlopen`/`dlsym`, declared against the system C
//! library since only `std` may be used) and the C ABI of `libpqkernels`
//! (`native-kernels/include/pq_kernels.h`, ABI version 1) as function
//! pointer types.

use std::ffi::{CStr, CString, c_char, c_int, c_void};

/// `PQK_ABI_VERSION` this engine is written against.
pub const PQK_ABI_VERSION: c_int = 1;
pub const PQK_OK: c_int = 0;
pub const PQK_OVERFLOW: c_int = 1;
pub const PQK_EINVAL: c_int = 2;

const RTLD_NOW: c_int = 2;
const RTLD_LOCAL: c_int = 0;

unsafe extern "C" {
    fn dlopen(filename: *const c_char, flag: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    fn dlerror() -> *mut c_char;
}

// Function pointer types, one per exported kernel (see pq_kernels.h).
pub type AbiVersionFn = unsafe extern "C" fn() -> c_int;
pub type InitFn = unsafe extern "C" fn() -> c_int;
pub type VariantFn = unsafe extern "C" fn() -> *const c_char;
pub type FilterI64Fn =
    unsafe extern "C" fn(*const i64, *const u8, usize, c_int, i64, i64, *mut u32) -> usize;
pub type FilterI64BitmapFn =
    unsafe extern "C" fn(*const i64, *const u8, usize, c_int, i64, i64, *mut u8) -> usize;
pub type SumI64Fn = unsafe extern "C" fn(*const i64, *const u8, usize, *mut i64) -> c_int;
pub type MinMaxI64Fn =
    unsafe extern "C" fn(*const i64, *const u8, usize, *mut i64, *mut i64) -> usize;
pub type MinMaxF64Fn =
    unsafe extern "C" fn(*const f64, *const u8, usize, *mut f64, *mut f64) -> usize;
pub type CountI64Fn = unsafe extern "C" fn(*const i64, *const u8, usize, c_int, i64, i64) -> usize;
pub type BitmapBinFn = unsafe extern "C" fn(*const u8, *const u8, *mut u8, usize);
pub type PopcountFn = unsafe extern "C" fn(*const u8, usize) -> usize;
pub type HashI64Fn = unsafe extern "C" fn(*const i64, usize, u64, *mut u64);
pub type CompareI64Fn =
    unsafe extern "C" fn(*const i64, *const i64, usize, c_int, *mut u8) -> usize;
pub type GroupSumI64Fn = unsafe extern "C" fn(
    *const u32,
    *const i64,
    *const u8,
    usize,
    *mut i64,
    *mut i64,
    usize,
) -> c_int;
pub type GatherI64Fn = unsafe extern "C" fn(*const i64, *const u32, usize, *mut i64);

/// An open shared library. The handle is never closed: kernels stay
/// callable for the lifetime of the process.
pub struct Library {
    handle: *mut c_void,
}

// SAFETY: a dlopen handle may be used from any thread (dlsym is MT-safe).
unsafe impl Send for Library {}
unsafe impl Sync for Library {}

fn last_dl_error() -> String {
    // SAFETY: dlerror returns NULL or a NUL-terminated thread-local string.
    let p = unsafe { dlerror() };
    if p.is_null() {
        "unknown dynamic loader error".to_string()
    } else {
        // SAFETY: non-null, NUL-terminated (see above).
        unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
    }
}

impl Library {
    pub fn open(path: &std::path::Path) -> Result<Library, String> {
        let c = CString::new(path.as_os_str().as_encoded_bytes())
            .map_err(|_| "library path contains a NUL byte".to_string())?;
        // SAFETY: `c` is a valid NUL-terminated path; loading runs the
        // library's (trivial) initializers.
        let handle = unsafe { dlopen(c.as_ptr(), RTLD_NOW | RTLD_LOCAL) };
        if handle.is_null() {
            return Err(last_dl_error());
        }
        Ok(Library { handle })
    }

    /// Address of symbol `name` (non-null).
    pub fn symbol(&self, name: &str) -> Result<*mut c_void, String> {
        let c = CString::new(name).map_err(|_| "bad symbol name".to_string())?;
        // SAFETY: valid handle and NUL-terminated name.
        let p = unsafe { dlsym(self.handle, c.as_ptr()) };
        if p.is_null() {
            return Err(format!("missing symbol {name}"));
        }
        Ok(p)
    }
}

/// Reads a static C string returned by the library.
///
/// # Safety
/// `p` must be NULL or point to a NUL-terminated string.
pub unsafe fn static_str(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    // SAFETY: guaranteed by the caller.
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}
