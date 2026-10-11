# Native Kernels

The native kernel library `libpqkernels` (`native-kernels/`) exposes a stable C
ABI defined in `native-kernels/include/pq_kernels.h` (ABI version 1; revision 1
adds the 128-bit kernels of CR-4, `../changes/kernels-i128.md`). It is
built from:

* `reference-c/` — portable C17 reference implementation (normative semantics);
* `x86_64/` — System V AMD64 assembly: scalar and AVX2 variants (optional AVX-512);
* `arm64/` — AArch64 assembly: scalar and NEON variants (optional SVE).

Runtime dispatch (`pq_kernels_init`) selects the best variant supported by the
CPU (CPUID / `getauxval(AT_HWCAP)`), overridable with the environment variable
`PQ_KERNELS_VARIANT=reference|scalar|avx2|avx512|neon|sve`.

Engines integrate the library through their language's FFI (Java FFM API,
Clojure via Java FFM, Rust `extern "C"`, Python `ctypes`, Go cgo, SBCL
`sb-alien`). Native kernels are **optional**: engines MUST produce identical
results with and without them, and MUST NOT require them for conformance.

Kernel semantics are documented in the header. Overflow semantics: integer sum
kernels report overflow via a status flag rather than wrapping silently.
