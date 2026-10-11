# Change request CR-5: behaviour-preserving restructuring of the assembly kernels

Status: adopted for the *refactoring* experiment family of the native kernels
(x86-64 and AArch64 assembly). Applies identically to both assembly languages.
No externally visible behaviour may change: the ABI, every kernel's results and
the set of variants and kernels each variant provides stay exactly the same.

## 1. Goal

The kernels were written variant by variant. CR-5 asks for the structure a
maintainer would want before further changes: shared building blocks defined
once, a uniform shape per kernel, and documentation that lets someone find and
change one kernel without reading the others.

## 2. Required structure

1. **Shared building blocks, defined once per architecture.** Code that is
   needed by more than one variant or kernel (at least: operator validation and
   dispatch for the comparison operators, validity-bit extraction, the
   function prologue/epilogue and symbol directives, constant tables) lives in
   one shared include file (or a small number of them) in the language's work
   directory, included by the variant sources. Each such building block is
   defined in exactly one place.
2. **Uniform kernel shape.** Every kernel in every variant follows the same
   documented skeleton: argument check / empty input, main (vector) loop, tail,
   result. Local labels follow one naming scheme across files.
3. **Per-kernel header comment** stating arguments (registers), clobbered
   registers, the algorithm and the tail strategy.
4. **Module map.** The work directory's `README.md` contains a before/after
   module map (files, what each contains, line counts) and lists every shared
   building block with the kernels that use it.

## 3. Constraints

* Bit-identical results: the differential tests and the acceptance tests pass
  for every variant that was built before, with the same number of kernels per
  variant.
* No new variants, no new kernels, no algorithmic rewrites. Performance should
  not regress; the throughput of every kernel is measured independently before
  and after the change on native hardware and reported (a regression is
  recorded as a finding, it does not fail the task).
* Only files in the language's work directory may change.
