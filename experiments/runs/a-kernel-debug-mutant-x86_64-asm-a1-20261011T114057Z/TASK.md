# PolyQuery native kernel task — Debugging — reported defect

You are an autonomous software engineer implementing the performance-critical
native kernels of **PolyQuery** in **x86-64 assembly**. You work alone, unattended,
in this workspace. Nobody will answer questions; make reasonable decisions
yourself and document them in `native-kernels/x86_64/README.md`.

## Your goal

A defect has been introduced into your accepted kernels in `native-kernels/x86_64/` (a single small source change). `DEFECT.md` in the workspace root contains the bug report as an engine developer wrote it: it describes the symptom, not the cause, and the public tests do not detect it. Reproduce the problem, find the root cause and fix it with a minimal change; do not rewrite unrelated code. You may write throwaway reproduction programs outside `native-kernels/x86_64/` (for example in /tmp), but do not commit them.

## Specification

* `native-kernels/include/pq_kernels.h` — the stable C ABI and the **normative
  semantics** of every kernel (read every comment carefully: validity bitmaps,
  unaligned pointers, empty inputs, overflow rules, invalid ops).
* `native-kernels/reference-c/pq_kernels_ref.c` — the portable C17 reference
  implementation. Your variants must produce bit-identical results (except
  `sum_f64`, whose tolerance is documented in the header).
* `native-kernels/reference-c/pq_dispatch.c` — runtime dispatch. Variants are
  discovered through **weak symbols** named `pqk_<variant>_<kernel>` (e.g.
  `pqk_x86_scalar_sum_i64`); a kernel a variant does not define
  falls back to the reference. CPU-feature detection is already implemented.
* `spec/phases/native-kernels.md` — context.

## Rules (experimental controls — mandatory)

1. Write all code under `native-kernels/x86_64/` (assembly sources `*.S`, README, notes).
   Do not modify anything else (header, reference, dispatcher, tests, Makefile).
   The Makefile automatically assembles every `native-kernels/x86_64/*.S` file.
2. Toolchain: GNU assembler (binutils 2.42) driven by gcc 13.3 on the native x86-64 host (AMD Zen 5: AVX2, BMI2, POPCNT and AVX-512F/BW/VL/DQ are available). NASM is installed but the build uses GNU `as` (`.S` files, AT&T or `.intel_syntax noprefix`).
3. Write real assembly (GNU `as` syntax via `.S` files, C preprocessor allowed
   for constants/macros). No C, no compiler intrinsics, no generated code from a
   compiler (do not compile C to assembly and paste it).
4. Follow the platform ABI exactly (System V AMD64): argument registers, callee-saved
   registers, stack alignment, no red-zone assumptions you cannot justify,
   proper `.type`/`.size` directives, and a `.note.GNU-stack` section.
5. Handle unaligned pointers, `n == 0` (possibly NULL pointers), and tails that
   are not multiples of the vector width. Never read or write outside the
   documented buffers (the tests run under AddressSanitizer for the C side, and
   buffers are deliberately unaligned).
6. Commit your work to git regularly with meaningful messages.

## How to test

```bash
make -C native-kernels test        # differential tests vs. the reference (runs natively, plus ASan/UBSan build)
make -C native-kernels bench       # micro-benchmarks (native architecture only)
```

## Definition of done

`make -C native-kernels test` passes for every variant (with the same kernel counts as before); the diff inside `native-kernels/x86_64/` is minimal; your final summary names the root cause (file, line, what was wrong) and how you reproduced it; all work is committed.

When done, make sure everything is committed, then finish with a short summary:
what you implemented, test results, measured speedups (if native), and
limitations.
