# PolyQuery native kernel task — Debugging — reported defect

You are an autonomous software engineer implementing the performance-critical
native kernels of **PolyQuery** in **AArch64 assembly**. You work alone, unattended,
in this workspace. Nobody will answer questions; make reasonable decisions
yourself and document them in `native-kernels/arm64/README.md`.

## Your goal

A defect has been introduced into your accepted kernels in `native-kernels/arm64/` (a single small source change). `DEFECT.md` in the workspace root contains the bug report as an engine developer wrote it: it describes the symptom, not the cause, and the public tests do not detect it. Reproduce the problem, find the root cause and fix it with a minimal change; do not rewrite unrelated code. You may write throwaway reproduction programs outside `native-kernels/arm64/` (for example in /tmp), but do not commit them.

## Specification

* `native-kernels/include/pq_kernels.h` — the stable C ABI and the **normative
  semantics** of every kernel (read every comment carefully: validity bitmaps,
  unaligned pointers, empty inputs, overflow rules, invalid ops).
* `native-kernels/reference-c/pq_kernels_ref.c` — the portable C17 reference
  implementation. Your variants must produce bit-identical results (except
  `sum_f64`, whose tolerance is documented in the header).
* `native-kernels/reference-c/pq_dispatch.c` — runtime dispatch. Variants are
  discovered through **weak symbols** named `pqk_<variant>_<kernel>` (e.g.
  `pqk_a64_scalar_sum_i64`); a kernel a variant does not define
  falls back to the reference. CPU-feature detection is already implemented.
* `spec/phases/native-kernels.md` — context.

## Rules (experimental controls — mandatory)

1. Write all code under `native-kernels/arm64/` (assembly sources `*.S`, README, notes).
   Do not modify anything else (header, reference, dispatcher, tests, Makefile).
   The Makefile automatically assembles every `native-kernels/arm64/*.S` file.
2. Toolchain: aarch64-linux-gnu-gcc 13.3 cross toolchain (GNU as). There is NO native AArch64 hardware: tests run under qemu-aarch64 user-mode emulation (`make -C native-kernels test-cross`), which verifies correctness only — emulated timings are meaningless, do not report them as performance.
3. Write real assembly (GNU `as` syntax via `.S` files, C preprocessor allowed
   for constants/macros). No C, no compiler intrinsics, no generated code from a
   compiler (do not compile C to assembly and paste it).
4. Follow the platform ABI exactly (AAPCS64 (Procedure Call Standard for the Arm 64-bit Architecture)): argument registers, callee-saved
   registers, stack alignment, no red-zone assumptions you cannot justify,
   proper `.type`/`.size` directives, and a `.note.GNU-stack` section.
5. Handle unaligned pointers, `n == 0` (possibly NULL pointers), and tails that
   are not multiples of the vector width. Never read or write outside the
   documented buffers (the tests run under AddressSanitizer for the C side, and
   buffers are deliberately unaligned).
6. Commit your work to git regularly with meaningful messages.

## How to test

```bash
make -C native-kernels test        # differential tests vs. the reference (AArch64 runs under qemu emulation: functional only)
make -C native-kernels bench       # micro-benchmarks (native architecture only)
```

## Definition of done

`make -C native-kernels test-cross` passes for every variant (with the same kernel counts as before); the diff inside `native-kernels/arm64/` is minimal; your final summary names the root cause (file, line, what was wrong) and how you reproduced it; all work is committed.

When done, make sure everything is committed, then finish with a short summary:
what you implemented, test results, measured speedups (if native), and
limitations.
